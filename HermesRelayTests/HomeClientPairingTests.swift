import Foundation
import XCTest
@testable import HermesRelayIOS

/// IOS-HOME-02 slice 1: pair from a link or typed code, keep one Keychain
/// credential per Home, renew before claiming, and make one fresh client
/// claim per connect. Every Home answer here is a deterministic fake.
final class HomeClientPairingTests: XCTestCase {
    private static let home = "https://home.example.ts.net"
    private static let credential = "device-credential-gen-1-secret"
    private static let renewedCredential = "device-credential-gen-2-secret"
    private static let pairingCode = "K7Q4MX2PNV"

    override func tearDown() {
        PairingTestDirectories.shared.removeAll()
        super.tearDown()
    }

    // MARK: Link opened / typed code

    func testPairingLinkPrefillsHomeAndCode() throws {
        let link = URL(string: "hermes-home://pair?home=https%3A%2F%2Fhome.example.ts.net&code=K7Q4MX2PNV")!
        let invitation = try HomePairingInvitation(link: link)

        XCTAssertEqual(invitation.home.url.absoluteString, Self.home)
        XCTAssertEqual(invitation.code, Self.pairingCode)
        XCTAssertEqual(
            invitation.home.bridgeEndpoint.absoluteString,
            "wss://home.example.ts.net/api/v1/bridge/ws"
        )
        XCTAssertFalse(String(describing: invitation).contains(Self.pairingCode))
    }

    func testMalformedOrNonHTTPSLinksAreRejectedWithSpecificMessages() {
        let cases: [(String, HomeClientPairingError)] = [
            ("https://home.example.ts.net/pair?code=K7Q4MX2PNV", .malformedLink),
            ("hermes-home://pair?home=https%3A%2F%2Fhome.example.ts.net", .malformedLink),
            ("hermes-home://pair?home=https%3A%2F%2Fa.example&code=K7Q4MX2PNV&extra=1", .malformedLink),
            ("hermes-home://other?home=https%3A%2F%2Fa.example&code=K7Q4MX2PNV", .malformedLink),
            ("hermes-home://pair?home=http%3A%2F%2Fhome.example.ts.net&code=K7Q4MX2PNV", .homeAddressNotHTTPS),
            ("hermes-home://pair?home=https%3A%2F%2Fu%3Ap%40home.example.ts.net&code=K7Q4MX2PNV", .homeAddressHasCredentials),
            ("hermes-home://pair?home=https%3A%2F%2Fhome.example.ts.net%3Fx%3D1&code=K7Q4MX2PNV", .homeAddressHasQueryOrFragment),
            ("hermes-home://pair?home=https%3A%2F%2Fhome.example.ts.net%2Fadmin&code=K7Q4MX2PNV", .homeAddressHasPath),
            ("hermes-home://pair?home=https%3A%2F%2Fhome.example.ts.net&code=%21%21", .invalidCode),
        ]
        for (text, expected) in cases {
            XCTAssertThrowsError(try HomePairingInvitation(linkText: text), text) { error in
                XCTAssertEqual(error as? HomeClientPairingError, expected, text)
                XCTAssertNotNil((error as? LocalizedError)?.errorDescription)
            }
        }
    }

    func testTypedCodeAcceptsAnyCaseWithOrWithoutTheDash() throws {
        for typed in ["k7q4m-x2pnv", "K7Q4MX2PNV", " k7q4m x2pnv "] {
            let invitation = try HomePairingInvitation(code: typed, homeAddress: Self.home)
            XCTAssertEqual(invitation.code, Self.pairingCode, typed)
        }
        let bareHost = try HomePairingInvitation(code: "k7q4mx2pnv", homeAddress: "home.example.ts.net:8443")
        XCTAssertEqual(bareHost.home.url.absoluteString, "https://home.example.ts.net:8443")
        XCTAssertEqual(
            bareHost.home.bridgeEndpoint.absoluteString,
            "wss://home.example.ts.net:8443/api/v1/bridge/ws"
        )
        XCTAssertThrowsError(try HomePairingInvitation(code: "K7Q4MX2PNV", homeAddress: "http://home.example")) {
            XCTAssertEqual($0 as? HomeClientPairingError, .homeAddressNotHTTPS)
        }
        XCTAssertThrowsError(try HomePairingInvitation(code: "", homeAddress: Self.home)) {
            XCTAssertEqual($0 as? HomeClientPairingError, .codeRequired)
        }
    }

    @MainActor
    func testMalformedLinkSubmitsNothing() async throws {
        let fixture = try await Self.makeFixture()
        let model = HomePairingModel(coordinator: fixture.coordinator)

        model.begin(link: URL(string: "hermes-home://pair?home=http%3A%2F%2Fhome.example&code=K7Q4MX2PNV")!)

        XCTAssertEqual(model.phase, .entry)
        XCTAssertEqual(model.entryError, HomeClientPairingError.homeAddressNotHTTPS.errorDescription)
        let calls = await fixture.service.calls
        XCTAssertEqual(calls, [])
    }

    // MARK: Wire shapes

    func testEnrollmentConsumeRenewAndClaimBodiesMatchTheHomeContract() async throws {
        let transport = ScriptedHomeTransport()
        let service = URLSessionHomeClientService(transport: transport)
        let home = try HomeClientBaseURL(Self.home)
        let endpointID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

        await transport.enqueue(200, json([
            "schema": 1, "request_id": "req-1", "confirmation_code": "ABCD1234", "expires_at": 1_800_000_300.0,
        ]))
        let pending = try await service.submitEnrollment(
            home: home,
            HomeEnrollmentSubmission(enrollmentCode: Self.pairingCode, endpointID: endpointID, label: "Amanda's iPhone", type: .ios)
        )
        XCTAssertEqual(pending.displayConfirmationCode, "ABCD-1234")

        await transport.enqueue(200, json(Self.materialJSON(credential: Self.credential, generation: 1)))
        let material = try await service.consumeEnrollment(home: home, requestID: "req-1", enrollmentCode: Self.pairingCode)
        XCTAssertEqual(material.clientGrants.map(\.grantID), ["grant-a", "grant-b"])

        await transport.enqueue(200, json(Self.materialJSON(credential: Self.renewedCredential, generation: 2)))
        _ = try await service.renewCredential(
            home: home, deviceID: "id-7", credential: Data(Self.credential.utf8), requestID: "renew-1", generation: 1
        )

        await transport.enqueue(200, json([
            "schema": 1, "claim_id": "client-1", "decision": "granted", "configuration_revision": 13,
            "conversation_handle": "opaque-handle-1", "session": ["mode": "new"],
        ]))
        let grant = try await service.claimConversation(
            home: home,
            credential: Data(Self.credential.utf8),
            HomeClientClaimRequest(claimID: "client-1", deviceID: "id-7", configurationRevision: 13, grantID: "grant-a")
        )
        XCTAssertEqual(grant.conversationHandle, "opaque-handle-1")
        XCTAssertFalse(String(describing: grant).contains("opaque-handle-1"))
        XCTAssertFalse(String(describing: material).contains(Self.credential))

        let requests = await transport.requests
        XCTAssertEqual(requests.map(\.path), [
            "/api/v1/enrollment/requests",
            "/api/v1/enrollment/requests/req-1/consume",
            "/api/v1/devices/id-7/credentials/renew",
            "/api/v1/client-claims",
        ])
        XCTAssertEqual(requests[0].authorization, nil)
        XCTAssertEqual(requests[0].body, [
            "schema": 1,
            "enrollment_code": Self.pairingCode,
            "endpoint_id": "11111111-2222-3333-4444-555555555555",
            "label": "Amanda's iPhone",
            "type": "ios",
            "requested_rooms": [String](),
            "requested_capabilities": ["client_claim"],
            "secure_storage": "platform_secure_store",
        ] as NSDictionary)
        XCTAssertEqual(requests[1].body, [
            "schema": 1, "enrollment_code": Self.pairingCode, "secure_storage": "platform_secure_store",
        ] as NSDictionary)
        XCTAssertEqual(requests[2].body, ["schema": 1, "request_id": "renew-1", "generation": 1] as NSDictionary)
        XCTAssertEqual(requests[2].authorization, "Device \(Self.credential)")
        XCTAssertEqual(requests[3].body, [
            "schema": 1, "claim_id": "client-1", "device_id": "id-7", "configuration_revision": 13,
            "grant_id": "grant-a", "session": ["mode": "new"],
        ] as NSDictionary)
        // A client claim never names a room, wake mapping or acoustic evidence.
        for key in ["room_id", "wake_mapping_id", "evidence", "profile_id"] {
            XCTAssertNil(requests[3].body?[key], key)
        }
    }

    func testTypedDenialsAndUnknownFieldsAreRejected() async throws {
        let transport = ScriptedHomeTransport()
        let service = URLSessionHomeClientService(transport: transport)
        let home = try HomeClientBaseURL(Self.home)
        let denials: [(Int, String, HomeClientDenial)] = [
            (409, "approval_pending", .approvalPending),
            (403, "rejected", .rejected),
            (410, "expired_or_consumed", .expiredOrConsumed),
            (409, "grant_pending", .grantPending),
            (409, "profile_unavailable", .profileUnavailable),
            (403, "client_claim_unavailable", .clientClaimUnavailable),
            (409, "claim_limit", .claimLimit),
            (409, "stale_configuration", .staleConfiguration),
            (401, "unauthorized", .unauthorized),
        ]
        for (status, code, expected) in denials {
            await transport.enqueue(status, json(["schema": 1, "error": ["code": code]]))
            do {
                _ = try await service.consumeEnrollment(home: home, requestID: "r", enrollmentCode: "c")
                XCTFail("\(code) must throw")
            } catch {
                XCTAssertEqual(error as? HomeClientServiceError, .denied(expected), code)
            }
        }
        var unknown = Self.materialJSON(credential: Self.credential, generation: 1)
        unknown["profile_id"] = "profile-secret"
        await transport.enqueue(200, json(unknown))
        do {
            _ = try await service.consumeEnrollment(home: home, requestID: "r", enrollmentCode: "c")
            XCTFail("An unknown field must be rejected")
        } catch {
            XCTAssertEqual(error as? HomeClientServiceError, .invalidResponse)
        }
    }

    func testEndpointIDIsStablePerInstallPerHome() async throws {
        let fixture = try await Self.makeFixture()
        let invitation = try HomePairingInvitation(code: Self.pairingCode, homeAddress: Self.home)
        let other = try HomePairingInvitation(code: Self.pairingCode, homeAddress: "https://other.example")

        _ = try await fixture.coordinator.submit(invitation)
        _ = try await fixture.coordinator.submit(invitation)
        _ = try await fixture.coordinator.submit(other)

        let submissions = await fixture.service.submissions
        XCTAssertEqual(submissions.count, 3)
        XCTAssertEqual(submissions[0].endpointID, submissions[1].endpointID)
        XCTAssertNotEqual(submissions[0].endpointID, submissions[2].endpointID)
        XCTAssertEqual(submissions[0].type, HomeClientEndpointType.current)
    }

    // MARK: Waiting / rejected / expired

    func testWaitingPollsAboutEveryTwoSecondsUntilApproval() async throws {
        let fixture = try await Self.makeFixture()
        let invitation = try HomePairingInvitation(code: Self.pairingCode, homeAddress: Self.home)
        await fixture.service.setConsumeResults([
            .failure(.denied(.approvalPending)),
            .failure(.denied(.approvalPending)),
            .success(Self.material(generation: 1)),
        ])
        let request = try await fixture.coordinator.submit(invitation)

        let approved = try await fixture.coordinator.awaitApproval(invitation, request: request)

        XCTAssertEqual(approved.generation, 1)
        let sleeps = fixture.sleeps.recorded
        XCTAssertEqual(sleeps, [.seconds(2), .seconds(2)])
        let calls = await fixture.service.calls
        XCTAssertEqual(calls, [.submit, .consume, .consume, .consume])
    }

    func testWaitingEndsAtExpiresAt() async throws {
        let fixture = try await Self.makeFixture()
        let invitation = try HomePairingInvitation(code: Self.pairingCode, homeAddress: Self.home)
        await fixture.service.setPendingRequest(HomeEnrollmentPendingRequest(
            requestID: "req-1",
            confirmationCode: "ABCD1234",
            expiresAt: fixture.clock.now.addingTimeInterval(5)
        ))
        await fixture.service.setConsumeResults([.failure(.denied(.approvalPending))])
        fixture.sleeps.onSleep = { fixture.clock.advance(by: 2) }
        let request = try await fixture.coordinator.submit(invitation)

        do {
            _ = try await fixture.coordinator.awaitApproval(invitation, request: request)
            XCTFail("Waiting must stop at expires_at")
        } catch {
            XCTAssertEqual(error as? HomePairingFlowError, .expired)
        }
        let allCalls = await fixture.service.calls
        let consumeCount = allCalls.filter { $0 == .consume }.count
        XCTAssertEqual(consumeCount, 3)
    }

    func testRejectedAndExpiredAreTerminalAndStoreNothing() async throws {
        for (denial, expected) in [
            (HomeClientDenial.rejected, HomePairingFlowError.rejected),
            (.expiredOrConsumed, .expiredOrConsumed),
        ] {
            let fixture = try await Self.makeFixture()
            let invitation = try HomePairingInvitation(code: Self.pairingCode, homeAddress: Self.home)
            await fixture.service.setConsumeResults([.failure(.denied(denial))])
            let request = try await fixture.coordinator.submit(invitation)

            do {
                _ = try await fixture.coordinator.finishPairing(invitation, request: request)
                XCTFail("\(denial) must be terminal")
            } catch {
                XCTAssertEqual(error as? HomePairingFlowError, expected)
            }
            let pairings = try await fixture.pairings.pairings()
            XCTAssertTrue(pairings.isEmpty)
            XCTAssertTrue(fixture.secure.isEmpty)
            let profiles = try await fixture.configuration.loadCollection().profiles
            XCTAssertTrue(profiles.isEmpty)
        }
    }

    // MARK: Approved

    func testApprovalStoresOneCredentialPerHomeAndOneProfilePerActiveGrant() async throws {
        let fixture = try await Self.makeFixture()
        let summary = try await Self.pair(fixture)

        XCTAssertNil(summary.activationFailure)
        XCTAssertTrue(summary.routePinned)
        XCTAssertEqual(summary.grants.map(\.label), ["Amanda", "Kitchen", "Jensen"])
        XCTAssertEqual(summary.grants.map(\.profileName), [
            "Amanda · home.example.ts.net", "Kitchen · home.example.ts.net", nil,
        ])
        XCTAssertTrue(summary.grants[2].isWaitingForOwner)

        let pairing = try await Self.firstPairing(fixture)
        XCTAssertEqual(pairing.profiles.count, 2)
        XCTAssertEqual(pairing.pinnedRouteID, "home-local")
        XCTAssertEqual(
            fixture.secure.value(account: HomeCredentialKeychain.account(forPairing: pairing.id)),
            Data(Self.credential.utf8)
        )
        // One credential for the Home, not one per profile.
        XCTAssertEqual(fixture.secure.valueCount(matching: Data(Self.credential.utf8)), 1)

        let collection = try await fixture.configuration.loadCollection()
        XCTAssertEqual(collection.profiles.count, 2)
        for profile in collection.profiles {
            XCTAssertEqual(collection.transportMode(for: profile.id), .home)
            XCTAssertEqual(collection.homeMigrations[profile.id]?.phase, .homeSelected)
        }
        XCTAssertEqual(collection.selectedID, pairing.profileID(for: "grant-a"))

        let headers = await fixture.sockets.authorizations
        XCTAssertEqual(headers, ["Device \(Self.credential)"])
        let proofMethods = await fixture.sockets.methods
        XCTAssertEqual(proofMethods, ["conversation.open", "conversation.close"])
    }

    func testHomeIsSelectedOnlyAfterTheFirstLiveReady() async throws {
        let fixture = try await Self.makeFixture(openSucceeds: false)
        let summary = try await Self.pair(fixture)

        XCTAssertNotNil(summary.activationFailure)
        XCTAssertFalse(summary.routePinned)
        let collection = try await fixture.configuration.loadCollection()
        XCTAssertEqual(collection.profiles.count, 2)
        for profile in collection.profiles {
            XCTAssertEqual(collection.transportMode(for: profile.id), .legacy)
        }
        XCTAssertNil(collection.selectedID.flatMap { collection.homeMigrations[$0] })
    }

    func testKeychainFailureSavesNoPairing() async throws {
        let fixture = try await Self.makeFixture(failingKeychain: true)
        let invitation = try HomePairingInvitation(code: Self.pairingCode, homeAddress: Self.home)
        await fixture.service.setConsumeResults([.success(Self.material(generation: 1))])
        let request = try await fixture.coordinator.submit(invitation)

        do {
            _ = try await fixture.coordinator.finishPairing(invitation, request: request)
            XCTFail("A Keychain failure must stop pairing")
        } catch {
            XCTAssertEqual(error as? HomePairingFlowError, .keychainFailure)
        }
        let pairings = try await fixture.pairings.pairings()
        XCTAssertTrue(pairings.isEmpty)
        let profiles = try await fixture.configuration.loadCollection().profiles
        XCTAssertTrue(profiles.isEmpty)
    }

    func testRefreshAddsAProfileWhenAGrantBecomesActive() async throws {
        let fixture = try await Self.makeFixture()
        let summary = try await Self.pair(fixture)
        await fixture.service.setConfigurationResults([.success(HomeClientDeviceConfiguration(
            revision: 14,
            clientGrants: Self.grants(jensen: .active)
        ))])

        let refreshed = try await fixture.coordinator.refresh(pairingID: summary.pairingID)

        XCTAssertEqual(refreshed.grants.compactMap(\.profileName).count, 3)
        let collection = try await fixture.configuration.loadCollection()
        XCTAssertEqual(collection.profiles.count, 3)
        for profile in collection.profiles {
            XCTAssertEqual(collection.transportMode(for: profile.id), .home)
        }
    }

    // MARK: Connect / renew / claim

    func testConnectReadsRevisionThenClaimsANewSession() async throws {
        let fixture = try await Self.makeFixture()
        let summary = try await Self.pair(fixture)
        let profileID = try await Self.profileID(fixture, grant: "grant-a")
        await fixture.service.resetCalls()

        let madeClaim = try await fixture.claims.claim(for: profileID)
        let claim = try XCTUnwrap(madeClaim)

        let calls = await fixture.service.calls
        XCTAssertEqual(calls, [.configuration, .claim(grantID: "grant-a", revision: 13)])
        XCTAssertEqual(claim.approvedRoute.identity, HomeRouteIdentity(routeClass: .home, id: "home-local"))
        XCTAssertFalse(claim.routePinPending)
        XCTAssertEqual(claim.approvedRoute.endpoint.absoluteString, "wss://home.example.ts.net/api/v1/bridge/ws")
        _ = summary
    }

    func testPastItsRenewalPointConnectRenewsBeforeClaimingAndStaysPaired() async throws {
        let fixture = try await Self.makeFixture()
        _ = try await Self.pair(fixture)
        let profileID = try await Self.profileID(fixture, grant: "grant-a")
        await fixture.service.resetCalls()
        // 80 days later: inside the last 14 days of the 90-day credential.
        fixture.clock.advance(by: 80 * 24 * 60 * 60)
        await fixture.service.setRenewResult(.success(Self.material(
            generation: 2,
            credential: Self.renewedCredential,
            expiresAt: fixture.clock.now.addingTimeInterval(90 * 24 * 60 * 60)
        )))

        let claim = try await fixture.claims.claim(for: profileID)

        XCTAssertNotNil(claim)
        let calls = await fixture.service.calls
        XCTAssertEqual(calls, [.renew(generation: 1), .configuration, .claim(grantID: "grant-a", revision: 13)])
        let seen = await fixture.service.credentialsSeen
        XCTAssertEqual(seen.first, Data(Self.credential.utf8))
        XCTAssertEqual(seen.last, Data(Self.renewedCredential.utf8))
        let pairing = try await Self.firstPairing(fixture)
        XCTAssertEqual(pairing.generation, 2)
        XCTAssertTrue(pairing.credentialUsable)
        XCTAssertNil(pairing.pendingRenewalRequestID)
        XCTAssertEqual(
            fixture.secure.value(account: HomeCredentialKeychain.account(forPairing: pairing.id)),
            Data(Self.renewedCredential.utf8)
        )
    }

    func testInterruptedRenewalFinishesFromKeychainWithoutAnotherRequest() async throws {
        let fixture = try await Self.makeFixture()
        _ = try await Self.pair(fixture)
        var pairing = try await Self.firstPairing(fixture)
        // Simulate a crash after Keychain took the renewed credential but
        // before the pairing record was updated.
        pairing.pendingRenewalRequestID = "renew-crashed"
        try await fixture.pairings.save(pairing)
        let renewedExpiry = HomeClientPairing.normalizedExpiry(pairing.credentialExpiresAt.addingTimeInterval(86_400))
        try await fixture.credentials.provision(
            preIssuedCredential: Data(Self.renewedCredential.utf8),
            reference: HomeClientPairing.credentialReference(pairingID: pairing.id, expiresAt: renewedExpiry),
            for: pairing.id
        )
        await fixture.service.resetCalls()

        let recovered = try await fixture.claims.renewIfDue(pairing)

        XCTAssertEqual(recovered.generation, 2)
        XCTAssertEqual(recovered.credentialExpiresAt, renewedExpiry)
        XCTAssertNil(recovered.pendingRenewalRequestID)
        let calls = await fixture.service.calls
        XCTAssertEqual(calls, [])
    }

    func testStaleConfigurationRefreshesOnceAndRetries() async throws {
        let fixture = try await Self.makeFixture()
        _ = try await Self.pair(fixture)
        let profileID = try await Self.profileID(fixture, grant: "grant-a")
        await fixture.service.resetCalls()
        await fixture.service.setConfigurationResults([
            .success(HomeClientDeviceConfiguration(revision: 13, clientGrants: Self.grants())),
            .success(HomeClientDeviceConfiguration(revision: 14, clientGrants: Self.grants())),
        ])
        await fixture.service.setClaimResults([.failure(.denied(.staleConfiguration)), .success("handle-2")])

        let claim = try await fixture.claims.claim(for: profileID)

        XCTAssertEqual(claim?.conversationHandle, "handle-2")
        let calls = await fixture.service.calls
        XCTAssertEqual(calls, [
            .configuration, .claim(grantID: "grant-a", revision: 13),
            .configuration, .claim(grantID: "grant-a", revision: 14),
        ])

        await fixture.service.resetCalls()
        await fixture.service.setClaimResults([.failure(.denied(.staleConfiguration))])
        do {
            _ = try await fixture.claims.claim(for: profileID)
            XCTFail("A second stale answer must not loop")
        } catch {
            XCTAssertEqual(error as? HomeClientConnectError, .denied(.staleConfiguration))
        }
        let retryCalls = await fixture.service.calls
        XCTAssertEqual(retryCalls.count, 4)
    }

    func testClaimDenialsArePlainAndSpecificWithoutRetry() async throws {
        let fixture = try await Self.makeFixture()
        _ = try await Self.pair(fixture)
        let profileID = try await Self.profileID(fixture, grant: "grant-a")
        for denial in [HomeClientDenial.grantPending, .profileUnavailable, .clientClaimUnavailable, .claimLimit] {
            await fixture.service.resetCalls()
            await fixture.service.setClaimResults([.failure(.denied(denial))])
            do {
                _ = try await fixture.claims.claim(for: profileID)
                XCTFail("\(denial) must be reported")
            } catch {
                let connectError = try XCTUnwrap(error as? HomeClientConnectError)
                XCTAssertEqual(connectError, .denied(denial))
                XCTAssertNotNil(connectError.errorDescription)
            }
            let calls = await fixture.service.calls
            XCTAssertEqual(calls.count, 2, "\(denial) must not be retried")
        }
        let pairing = try await Self.firstPairing(fixture)
        XCTAssertTrue(pairing.credentialUsable)
    }

    func testUnauthorizedMarksTheCredentialUnusableAndAsksToPairAgain() async throws {
        let fixture = try await Self.makeFixture()
        _ = try await Self.pair(fixture)
        let profileID = try await Self.profileID(fixture, grant: "grant-a")
        await fixture.service.setConfigurationResults([.failure(.denied(.unauthorized))])

        do {
            _ = try await fixture.claims.claim(for: profileID)
            XCTFail("401 must ask to pair again")
        } catch {
            XCTAssertEqual(error as? HomeClientConnectError, .pairAgain(home: "home.example.ts.net"))
            XCTAssertEqual(
                (error as? LocalizedError)?.errorDescription,
                "Pair again with home.example.ts.net."
            )
        }
        let pairing = try await Self.firstPairing(fixture)
        XCTAssertFalse(pairing.credentialUsable)

        await fixture.service.resetCalls()
        do {
            _ = try await fixture.claims.claim(for: profileID)
            XCTFail("An unusable credential must not be sent")
        } catch {
            XCTAssertEqual(error as? HomeClientConnectError, .pairAgain(home: "home.example.ts.net"))
        }
        let calls = await fixture.service.calls
        XCTAssertEqual(calls, [])
    }

    func testExpiredCredentialAsksToPairAgainWithoutSendingIt() async throws {
        let fixture = try await Self.makeFixture()
        _ = try await Self.pair(fixture)
        let profileID = try await Self.profileID(fixture, grant: "grant-a")
        await fixture.service.resetCalls()
        fixture.clock.advance(by: 91 * 24 * 60 * 60)

        do {
            _ = try await fixture.claims.claim(for: profileID)
            XCTFail("An expired credential must ask to pair again")
        } catch {
            XCTAssertEqual(error as? HomeClientConnectError, .pairAgain(home: "home.example.ts.net"))
        }
        let calls = await fixture.service.calls
        XCTAssertEqual(calls, [])
        let pairing = try await Self.firstPairing(fixture)
        XCTAssertFalse(pairing.credentialUsable)
    }

    // MARK: Route pin

    func testLaterClaimsRequireThePinnedRoute() async throws {
        let fixture = try await Self.makeFixture()
        _ = try await Self.pair(fixture)
        let profileID = try await Self.profileID(fixture, grant: "grant-a")
        await fixture.sockets.setReadyRouteID("home-other")
        let madeClaim = try await fixture.claims.claim(for: profileID)
        let claim = try XCTUnwrap(madeClaim)
        let client = fixture.bridgeFactory.make(profileID: profileID, mode: .home)

        let outcome = await client.open(claim: claim)

        XCTAssertEqual(outcome, .unavailable(.route(.identityMismatch)))
        let pairing = try await Self.firstPairing(fixture)
        XCTAssertEqual(pairing.pinnedRouteID, "home-local")
        await client.close()
    }

    func testAnUnpinnedClaimFailsClosedWithoutARecorder() async throws {
        let claim = HomeConversationClaim(
            profileID: UUID(),
            conversationHandle: "opaque",
            approvedRoute: HomeApprovedRoute(
                endpoint: URL(string: "wss://home.example/api/v1/bridge/ws")!,
                identity: HomeRouteIdentity(routeClass: .home, id: HomeRouteIdentity.pendingPinID),
                householdBinding: "home.example"
            ),
            routePinPending: true
        )
        let client = URLSessionHomeBridgeSessionClient(dependencies: HomeBridgeClientDependencies(
            routeProvider: FixedPairingRouteProvider(route: claim.approvedRoute),
            credentialStore: InMemoryHomeCredentialStore(),
            publicAdapterEnabled: true
        ))

        let outcome = await client.open(claim: claim)

        XCTAssertEqual(outcome, .unavailable(.route(.identityMismatch)))
    }

    // MARK: Conversation store

    @MainActor
    func testPairedConnectCompletesATypedTurnWithoutAPastedCredentialOrHandle() async throws {
        let fixture = try await Self.makeFixture()
        _ = try await Self.pair(fixture)
        let store = fixture.makeStore()
        await fixture.service.resetCalls()

        let loaded = await store.loadConfiguredClient()
        XCTAssertTrue(loaded)
        let loadCalls = await fixture.service.calls
        XCTAssertEqual(loadCalls, [], "A claim is made in connect, never at load")
        await store.connect()

        XCTAssertEqual(store.connectionState, .connected)
        XCTAssertEqual(store.homeBridgeState.isReady, true)
        let connectCalls = await fixture.service.calls
        XCTAssertEqual(connectCalls, [.configuration, .claim(grantID: "grant-a", revision: 13)])
        let client = try XCTUnwrap(fixture.echo.clients.last)
        await client.completeNextTurn(with: "Hello from Hermes")

        let completed = await store.sendTurn(text: "Hello Hermes")

        XCTAssertTrue(completed)
        XCTAssertEqual(store.messages.map(\.text), ["Hello Hermes", "Hello from Hermes"])
        let submitted = await client.submittedTexts
        XCTAssertEqual(submitted, ["Hello Hermes"])
    }

    @MainActor
    func testANewSessionOnAProfileWithHistoryAddsALocalDivider() async throws {
        let fixture = try await Self.makeFixture()
        _ = try await Self.pair(fixture)
        let profileID = try await Self.profileID(fixture, grant: "grant-a")
        let persistence = JSONConversationPersistence(
            fileURL: ConversationPersistenceFile.url(in: fixture.directory, for: profileID)
        )
        try await persistence.save(PersistedConversation(
            messages: [TranscriptMessage(role: .user, text: "Earlier"), TranscriptMessage(role: .assistant, text: "Reply")],
            draft: ""
        ))
        let store = fixture.makeStore()

        await store.loadConfiguredClient()
        await store.loadPersistedConversation()
        await store.connect()

        XCTAssertEqual(store.messages.last?.role, .system)
        XCTAssertEqual(store.messages.last?.text, ConversationStore.newHomeConversationDividerText)
        await store.disconnect()
        await store.connect()
        XCTAssertEqual(
            store.messages.filter { $0.text == ConversationStore.newHomeConversationDividerText }.count,
            1,
            "Consecutive new sessions without messages keep one divider"
        )
        let submitted = await fixture.echo.allSubmittedTexts()
        XCTAssertEqual(submitted, [], "Earlier messages are never sent to Hermes")
    }

    @MainActor
    func testExplicitDisconnectAndProfileSwitchCloseThePairedConversation() async throws {
        let fixture = try await Self.makeFixture()
        _ = try await Self.pair(fixture)
        let store = fixture.makeStore()
        await store.loadConfiguredClient()
        await store.connect()

        await store.disconnect()

        XCTAssertEqual(store.connectionState, .disconnected)
        var closes = await fixture.echo.totalConversationCloses()
        XCTAssertEqual(closes, 1)
        await fixture.service.resetCalls()
        await store.connect()
        XCTAssertEqual(store.connectionState, .connected)
        let reconnectCalls = await fixture.service.calls
        XCTAssertEqual(reconnectCalls.last, .claim(grantID: "grant-a", revision: 13), "A new connect makes a fresh claim")

        await store.clearSelectedProfile()
        closes = await fixture.echo.totalConversationCloses()
        XCTAssertEqual(closes, 2)
    }

    @MainActor
    func testAHeldClaimIsReopenedAfterForegroundAndReplacedOnceItHasEnded() async throws {
        let fixture = try await Self.makeFixture()
        _ = try await Self.pair(fixture)
        let store = fixture.makeStore()
        await store.loadConfiguredClient()
        await store.connect()
        let firstHandle = try XCTUnwrap(fixture.echo.clients.last?.openedHandlesSnapshot.last)
        await fixture.service.resetCalls()

        // Background and foreground within Home's reconnect grace.
        _ = store.takeHomeClientForLifecycle()
        await store.loadConfiguredClient()
        await store.connect()

        XCTAssertEqual(store.connectionState, .connected)
        XCTAssertEqual(fixture.echo.clients.last?.openedHandlesSnapshot, [firstHandle])
        let reopenCalls = await fixture.service.calls
        XCTAssertEqual(reopenCalls, [], "A held claim is reopened, not replaced")

        // Home has since closed that claim: this connect makes one fresh claim.
        fixture.echo.end(handle: firstHandle)
        _ = store.takeHomeClientForLifecycle()
        await store.loadConfiguredClient()
        await store.connect()

        XCTAssertEqual(store.connectionState, .connected)
        let replacedCalls = await fixture.service.calls
        XCTAssertEqual(replacedCalls, [.configuration, .claim(grantID: "grant-a", revision: 13)])
        XCTAssertNotEqual(fixture.echo.clients.last?.openedHandlesSnapshot.last, firstHandle)
    }

    @MainActor
    func testClaimDenialLeavesASpecificDisconnectedState() async throws {
        let fixture = try await Self.makeFixture()
        _ = try await Self.pair(fixture)
        let store = fixture.makeStore()
        await fixture.service.setClaimResults([.failure(.denied(.grantPending))])
        await store.loadConfiguredClient()

        await store.connect()

        XCTAssertEqual(store.connectionState, .disconnected)
        XCTAssertEqual(store.transientError, HomeClientConnectError.denied(.grantPending).errorDescription)
        XCTAssertTrue(fixture.echo.clients.allSatisfy { $0.openCount == 0 })
    }

    @MainActor
    func testAnUncertainTurnIsNeverReplayedAfterContinuityIsLost() async throws {
        let fixture = try await Self.makeFixture()
        _ = try await Self.pair(fixture)
        let store = fixture.makeStore()
        await store.loadConfiguredClient()
        await store.connect()
        let client = try XCTUnwrap(fixture.echo.clients.last)
        await client.setNextSubmission(.uncertain(.home(code: .transportTimeout, phase: .submission)))

        _ = await store.sendTurn(text: "maybe sent")

        // Relaunch: the paired claim's handle was never written to disk.
        let relaunched = fixture.makeStore()
        await fixture.service.resetCalls()
        await relaunched.loadConfiguredClient()
        await relaunched.loadPersistedConversation()
        await relaunched.connect()

        XCTAssertEqual(relaunched.connectionState, .disconnected)
        XCTAssertTrue(relaunched.canStartNewHomeConversation)
        XCTAssertNotNil(relaunched.transientError)
        let noClaim = await fixture.service.calls
        XCTAssertEqual(noClaim, [], "No claim is made until the user chooses a new conversation")

        let started = await relaunched.startNewHomeConversation()

        XCTAssertTrue(started)
        XCTAssertEqual(relaunched.connectionState, .connected)
        XCTAssertNil(relaunched.unconfirmedTurnText)
        let submitted = await fixture.echo.allSubmittedTexts()
        XCTAssertEqual(submitted, ["maybe sent"], "The uncertain turn was submitted once and never replayed")
    }

    @MainActor
    func testNoSecretHandleOrProfileIDReachesAnyPersistedFile() async throws {
        let fixture = try await Self.makeFixture()
        _ = try await Self.pair(fixture)
        let profileID = try await Self.profileID(fixture, grant: "grant-a")
        let store = fixture.makeStore()
        await store.loadConfiguredClient()
        await store.connect()
        let client = try XCTUnwrap(fixture.echo.clients.last)
        let openedHandle = await client.lastOpenedHandle()
        let handle = try XCTUnwrap(openedHandle)
        await client.setNextSubmission(.uncertain(.home(code: .transportTimeout, phase: .submission)))
        _ = await store.sendTurn(text: "persisted prompt")

        let recovery = try await JSONConversationPersistence(
            fileURL: ConversationPersistenceFile.url(in: fixture.directory, for: profileID)
        ).load().homeRecovery
        XCTAssertEqual(recovery?.conversationHandle, PersistedHomeRecovery.redactedHandle)

        let files = try FileManager.default.contentsOfDirectory(at: fixture.directory, includingPropertiesForKeys: nil)
        XCTAssertFalse(files.isEmpty)
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for forbidden in [Self.credential, Self.pairingCode, handle, "profile_id", "session_ref", "sref-"] {
                XCTAssertFalse(text.contains(forbidden), "\(file.lastPathComponent) contains \(forbidden)")
            }
        }
    }

    // MARK: Legacy and removal

    @MainActor
    func testOperatorHandleProfilesBehaveExactlyAsBefore() async throws {
        let fixture = try await Self.makeFixture()
        let profile = try RelayProfile(
            endpoint: URL(string: "wss://home.example/api/v1/bridge/ws")!,
            clientID: "hermes-ios-test",
            deviceID: "test",
            displayName: "Operator Home"
        )
        try await fixture.configuration.saveProfile(profile)
        let liveStore = JSONHomeLiveConfigurationStore(
            fileURL: fixture.directory.appendingPathComponent("home-live-configurations.json")
        )
        let route = HomeApprovedRoute(
            endpoint: profile.endpoint,
            identity: HomeRouteIdentity(routeClass: .home, id: "local"),
            householdBinding: "household"
        )
        try await liveStore.save(try HomeLiveConfiguration(
            profileID: profile.id,
            conversationHandle: "operator-handle",
            approvedRoute: route
        ))
        try await fixture.configuration.selectPairedHome(for: profile.id)
        let provider = AppHomeConversationClaimProvider(liveStore: liveStore, pairedClaims: fixture.claims)
        let claimsPerConnect = await provider.claimsPerConnect(for: profile.id)
        XCTAssertFalse(claimsPerConnect)
        let store = ConversationStore(
            configurationStore: fixture.configuration,
            homeClientFactory: fixture.echo,
            homeClaimProvider: provider
        )

        await store.loadConfiguredClient()
        await store.connect()
        await store.disconnect()

        XCTAssertEqual(fixture.echo.clients.first.map { $0.openedHandlesSnapshot }, ["operator-handle"])
        let closes = await fixture.echo.totalConversationCloses()
        XCTAssertEqual(closes, 0, "An operator handle is never closed by the app")
        let calls = await fixture.service.calls
        XCTAssertEqual(calls, [])
    }

    func testRemovingTheLastPairedProfileRemovesTheCredential() async throws {
        let fixture = try await Self.makeFixture()
        _ = try await Self.pair(fixture)
        let pairing = try await Self.firstPairing(fixture)
        let account = HomeCredentialKeychain.account(forPairing: pairing.id)
        let first = try XCTUnwrap(pairing.profileID(for: "grant-a"))
        let second = try XCTUnwrap(pairing.profileID(for: "grant-b"))

        try await fixture.configuration.deleteProfile(id: first)
        try await fixture.coordinator.profileRemoved(first)
        XCTAssertNotNil(fixture.secure.value(account: account))

        try await fixture.configuration.deleteProfile(id: second)
        try await fixture.coordinator.profileRemoved(second)
        XCTAssertNil(fixture.secure.value(account: account))
        let remaining = try await fixture.pairings.pairings()
        XCTAssertTrue(remaining.isEmpty)

        // Pairing again replaces the previous generation for this install.
        _ = try await fixture.coordinator.submit(try HomePairingInvitation(code: Self.pairingCode, homeAddress: Self.home))
        let submissions = await fixture.service.submissions
        XCTAssertEqual(submissions.first?.endpointID, submissions.last?.endpointID)
    }

    // MARK: Review follow-ups

    @MainActor
    func testForegroundCycleRestoresTheHeldHandleForAnUncertainPairedTurn() async throws {
        let fixture = try await Self.makeFixture()
        _ = try await Self.pair(fixture)
        let store = fixture.makeStore()
        await store.loadConfiguredClient()
        await store.connect()
        let firstClient = try XCTUnwrap(fixture.echo.clients.last)
        let openedHandle = await firstClient.lastOpenedHandle()
        let handle = try XCTUnwrap(openedHandle)
        await firstClient.setNextSubmission(.uncertain(.home(code: .transportTimeout, phase: .submission)))
        _ = await store.sendTurn(text: "maybe sent")
        await fixture.service.resetCalls()

        _ = store.takeHomeClientForLifecycle()
        await store.loadConfiguredClient()
        await store.loadPersistedConversation()
        await store.connect()

        XCTAssertEqual(store.connectionState, .connected)
        XCTAssertFalse(store.canStartNewHomeConversation)
        XCTAssertEqual(fixture.echo.clients.last?.openedHandlesSnapshot, [handle])
        let calls = await fixture.service.calls
        XCTAssertEqual(calls, [], "The held claim is reopened, not replaced")
        let submitted = await fixture.echo.allSubmittedTexts()
        XCTAssertEqual(submitted, ["maybe sent"])
    }

    func testInterruptedRenewalWithoutANewerCredentialRetriesTheSavedRequest() async throws {
        let fixture = try await Self.makeFixture()
        _ = try await Self.pair(fixture)
        let saved = try await Self.firstPairing(fixture)
        let pairing = try await fixture.pairings.update(pairingID: saved.id) {
            $0.pendingRenewalRequestID = "renew-saved"
        }
        await fixture.service.setRenewResult(.success(Self.material(
            generation: 2,
            credential: Self.renewedCredential,
            expiresAt: fixture.clock.now.addingTimeInterval(90 * 24 * 60 * 60)
        )))

        let renewed = try await fixture.claims.renewIfDue(pairing)

        let ids = await fixture.service.renewRequestIDs
        XCTAssertEqual(ids, ["renew-saved"])
        XCTAssertEqual(renewed.generation, 2)
        XCTAssertNil(renewed.pendingRenewalRequestID)
    }

    func testRenewalAnsweredWithConflictStillClaims() async throws {
        let fixture = try await Self.makeFixture()
        _ = try await Self.pair(fixture)
        let profileID = try await Self.profileID(fixture, grant: "grant-a")
        fixture.clock.advance(by: 80 * 24 * 60 * 60)
        await fixture.service.setRenewResult(.failure(.denied(.conflict)))
        await fixture.service.resetCalls()

        let claim = try await fixture.claims.claim(for: profileID)

        XCTAssertNotNil(claim)
        let calls = await fixture.service.calls
        XCTAssertEqual(calls, [.renew(generation: 1), .configuration, .claim(grantID: "grant-a", revision: 13)])
        let pairing = try await Self.firstPairing(fixture)
        XCTAssertEqual(pairing.generation, 1)
        XCTAssertNil(pairing.pendingRenewalRequestID)
    }

    @MainActor
    func testProfileListDeletionRemovesThePairingCredentialAndRecord() async throws {
        let fixture = try await Self.makeFixture()
        _ = try await Self.pair(fixture)
        let pairing = try await Self.firstPairing(fixture)
        let account = HomeCredentialKeychain.account(forPairing: pairing.id)
        let model = RelayProfileListModel(
            configurationStore: fixture.configuration,
            conversationDirectory: fixture.directory,
            homePairingCoordinator: fixture.coordinator
        )
        await model.load()
        XCTAssertEqual(model.pairedProfileIDs.count, 2)

        for profile in pairing.profiles {
            let deleted = await model.delete(id: profile.profileID)
            XCTAssertTrue(deleted)
        }

        XCTAssertNil(model.errorMessage)
        XCTAssertNil(fixture.secure.value(account: account))
        let remaining = try await fixture.pairings.pairings()
        XCTAssertTrue(remaining.isEmpty)
        XCTAssertTrue(model.pairedProfileIDs.isEmpty)
    }

    @MainActor
    func testPairingModelAnnouncesOnlyAnActivatedPairingOnce() async throws {
        for openSucceeds in [true, false] {
            let fixture = try await Self.makeFixture(openSucceeds: openSucceeds)
            await fixture.service.setConsumeResults([.success(Self.material(generation: 1))])
            let counter = PairingTestCounter()
            let model = HomePairingModel(coordinator: fixture.coordinator, onPaired: { counter.count += 1 })

            model.begin(link: URL(string: "hermes-home://pair?home=https%3A%2F%2Fhome.example.ts.net&code=K7Q4MX2PNV")!)
            for _ in 0..<300 {
                if case .finished = model.phase { break }
                try await Task.sleep(for: .milliseconds(10))
            }

            guard case .finished(let summary) = model.phase else {
                return XCTFail("Pairing must finish (openSucceeds: \(openSucceeds))")
            }
            XCTAssertEqual(summary.activationFailure == nil, openSucceeds)
            XCTAssertEqual(counter.count, openSucceeds ? 1 : 0)
        }

        let inbox = HomePairingLinkInbox()
        XCTAssertFalse(inbox.receive(URL(string: "https://home.example.ts.net/pair?code=K7Q4MX2PNV")!))
        XCTAssertNil(inbox.pendingLink)
        XCTAssertTrue(inbox.receive(URL(string: "hermes-home://pair?home=https%3A%2F%2Fa.example&code=K7Q4MX2PNV")!))
        XCTAssertNotNil(inbox.pendingLink)
    }

    func testADeletedPairedProfileIsNotRecreatedByRefresh() async throws {
        let fixture = try await Self.makeFixture()
        let summary = try await Self.pair(fixture)
        let removed = try await Self.profileID(fixture, grant: "grant-a")
        try await fixture.configuration.deleteProfile(id: removed)
        try await fixture.coordinator.profileRemoved(removed)

        _ = try await fixture.coordinator.refresh(pairingID: summary.pairingID)

        let collection = try await fixture.configuration.loadCollection()
        XCTAssertEqual(collection.profiles.map(\.displayName), ["Kitchen · home.example.ts.net"])
        let pairing = try await Self.firstPairing(fixture)
        XCTAssertEqual(pairing.unboundGrantIDs, ["grant-a"])
        XCTAssertNil(pairing.profileID(for: "grant-a"))
    }

    func testAStaleCopyNeverClearsThePinOrProfiles() async throws {
        let fixture = try await Self.makeFixture()
        _ = try await Self.pair(fixture)
        var stale = try await Self.firstPairing(fixture)
        // A copy read before the first ready pinned the route.
        stale.pinnedRouteID = nil
        stale.profiles = []
        fixture.clock.advance(by: 80 * 24 * 60 * 60)
        await fixture.service.setRenewResult(.success(Self.material(
            generation: 2,
            credential: Self.renewedCredential,
            expiresAt: fixture.clock.now.addingTimeInterval(90 * 24 * 60 * 60)
        )))

        _ = try await fixture.claims.renewIfDue(stale)

        let pairing = try await Self.firstPairing(fixture)
        XCTAssertEqual(pairing.pinnedRouteID, "home-local")
        XCTAssertEqual(pairing.profiles.count, 2)
        XCTAssertEqual(pairing.generation, 2)
    }

    func testACorruptPairingFileLeavesOperatorProfilesWorking() async throws {
        let fixture = try await Self.makeFixture()
        try Data("not json".utf8).write(to: fixture.directory.appendingPathComponent("home-client-pairings.json"))
        let profileID = UUID()
        let liveStore = JSONHomeLiveConfigurationStore(
            fileURL: fixture.directory.appendingPathComponent("home-live-configurations.json")
        )
        let route = HomeApprovedRoute(
            endpoint: URL(string: "wss://home.example/api/v1/bridge/ws")!,
            identity: HomeRouteIdentity(routeClass: .home, id: "local"),
            householdBinding: "household"
        )
        try await liveStore.save(try HomeLiveConfiguration(
            profileID: profileID,
            conversationHandle: "operator-handle",
            approvedRoute: route
        ))
        let provider = AppHomeConversationClaimProvider(liveStore: liveStore, pairedClaims: fixture.claims)

        let claim = try await provider.conversationClaim(for: profileID)
        let claimsPerConnect = await provider.claimsPerConnect(for: profileID)
        let approved = try await AppHomeApprovedRouteProvider(pairings: fixture.pairings, legacy: liveStore)
            .approvedRoute(for: profileID)

        XCTAssertEqual(claim?.conversationHandle, "operator-handle")
        XCTAssertFalse(claimsPerConnect)
        XCTAssertEqual(approved, route)
    }

    func testAnUnavailableFirstGrantDoesNotBlockActivation() async throws {
        let fixture = try await Self.makeFixture()
        let grants = [
            HomeClientGrant(grantID: "grant-a", label: "Amanda", status: .active, available: false),
            HomeClientGrant(grantID: "grant-b", label: "Kitchen", status: .active, available: true),
        ]
        await fixture.service.setConfigurationResults([.success(HomeClientDeviceConfiguration(
            revision: 13, clientGrants: grants
        ))])
        await fixture.service.setDeniedGrants(["grant-a": .profileUnavailable])

        let summary = try await Self.pair(fixture, grants: grants)

        XCTAssertNil(summary.activationFailure)
        XCTAssertTrue(summary.routePinned)
        let calls = await fixture.service.calls
        XCTAssertFalse(calls.contains(.claim(grantID: "grant-a", revision: 13)), "Available grants are tried first")
        let collection = try await fixture.configuration.loadCollection()
        let pairing = try await Self.firstPairing(fixture)
        XCTAssertEqual(collection.selectedID, pairing.profileID(for: "grant-b"))
    }

    func testActivationTriesEachActiveGrantUntilOneProves() async throws {
        let fixture = try await Self.makeFixture()
        await fixture.service.setDeniedGrants(["grant-a": .profileUnavailable])

        let summary = try await Self.pair(fixture)

        XCTAssertNil(summary.activationFailure)
        let calls = await fixture.service.calls
        XCTAssertTrue(calls.contains(.claim(grantID: "grant-a", revision: 13)))
        XCTAssertTrue(calls.contains(.claim(grantID: "grant-b", revision: 13)))
        let pairing = try await Self.firstPairing(fixture)
        let collection = try await fixture.configuration.loadCollection()
        XCTAssertEqual(collection.selectedID, pairing.profileID(for: "grant-b"))
        for profile in collection.profiles {
            XCTAssertEqual(collection.transportMode(for: profile.id), .home)
        }
    }

    func testDefaultHTTPSPortIsTheSameHome() throws {
        XCTAssertEqual(
            try HomeClientBaseURL("https://home.example.ts.net:443"),
            try HomeClientBaseURL("https://home.example.ts.net")
        )
        XCTAssertEqual(try HomeClientBaseURL("home.example.ts.net:8443").url.port, 8443)
    }

    func testPairingRecordsWithoutUnboundGrantsStillLoad() throws {
        let pairing = HomeClientPairing(
            home: try HomeClientBaseURL(Self.home),
            endpointID: UUID(),
            deviceID: "id-7",
            generation: 1,
            credentialExpiresAt: PairingTestClock.start
        )
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(pairing)) as? [String: Any]
        )
        object.removeValue(forKey: "unboundGrantIDs")
        let decoded = try JSONDecoder().decode(
            HomeClientPairing.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        XCTAssertEqual(decoded, pairing)
    }

    // MARK: - Fixture

    private static func pair(
        _ fixture: PairingFixture,
        grants: [HomeClientGrant] = HomeClientPairingTests.grants()
    ) async throws -> HomeClientPairingSummary {
        let invitation = try HomePairingInvitation(code: Self.pairingCode, homeAddress: Self.home)
        await fixture.service.setConsumeResults([.success(Self.material(generation: 1, grants: grants))])
        let request = try await fixture.coordinator.submit(invitation)
        return try await fixture.coordinator.finishPairing(invitation, request: request)
    }

    private static func firstPairing(_ fixture: PairingFixture) async throws -> HomeClientPairing {
        let pairings = try await fixture.pairings.pairings()
        return try XCTUnwrap(pairings.first)
    }

    private static func profileID(_ fixture: PairingFixture, grant: String) async throws -> UUID {
        let pairing = try await Self.firstPairing(fixture)
        return try XCTUnwrap(pairing.profileID(for: grant))
    }

    private static func grants(jensen: HomeClientGrantStatus = .pendingOwner) -> [HomeClientGrant] {
        [
            HomeClientGrant(grantID: "grant-a", label: "Amanda", status: .active, available: true),
            HomeClientGrant(grantID: "grant-b", label: "Kitchen", status: .active, available: true),
            HomeClientGrant(grantID: "grant-c", label: "Jensen", status: jensen, available: true),
        ]
    }

    private static func material(
        generation: Int,
        credential: String = HomeClientPairingTests.credential,
        expiresAt: Date? = nil,
        grants: [HomeClientGrant] = HomeClientPairingTests.grants()
    ) -> HomeCredentialMaterial {
        HomeCredentialMaterial(
            deviceID: "id-7",
            credential: Data(credential.utf8),
            generation: generation,
            expiresAt: expiresAt ?? PairingTestClock.start.addingTimeInterval(90 * 24 * 60 * 60 + 0.5),
            clientGrants: grants
        )
    }

    private static func materialJSON(credential: String, generation: Int) -> [String: Any] {
        [
            "schema": 1,
            "device_id": "id-7",
            "credential": credential,
            "generation": generation,
            "expires_at": 1_800_000_000.0,
            "scope": ["rooms": [String](), "capabilities": ["client_claim"], "wake_mappings": [String]()],
            "client_grants": [
                ["grant_id": "grant-a", "label": "Amanda", "status": "active", "available": true],
                ["grant_id": "grant-b", "label": "Jensen", "status": "pending_owner", "available": true],
            ],
        ]
    }

    private static func makeFixture(
        openSucceeds: Bool = true,
        failingKeychain: Bool = false
    ) async throws -> PairingFixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HomeClientPairingTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        PairingTestDirectories.shared.register(directory)
        let clock = PairingTestClock()
        let secure = PairingTestSecureStore(failWrites: failingKeychain)
        let configuration = RelayConfigurationStore(
            secureStore: secure,
            profileURL: directory.appendingPathComponent("profile.json"),
            now: { clock.now }
        )
        let pairings = JSONHomeClientPairingStore(
            fileURL: directory.appendingPathComponent("home-client-pairings.json")
        )
        let credentials = KeychainHomeCredentialStore(secureStore: secure)
        let service = FakeHomeClientService()
        await service.setConfigurationResults([.success(HomeClientDeviceConfiguration(
            revision: 13,
            clientGrants: Self.grants()
        ))])
        let claims = HomeClientClaimCoordinator(
            service: service,
            pairings: pairings,
            credentials: credentials,
            now: { clock.now }
        )
        let sockets = PairingTestSocketFactory(readyRouteID: "home-local", openSucceeds: openSucceeds)
        let bridgeFactory = DefaultHomeBridgeSessionClientFactory(dependencies: HomeBridgeClientDependencies(
            routeProvider: AppHomeApprovedRouteProvider(pairings: pairings, legacy: nil),
            credentialStore: PairingAwareHomeCredentialStore(pairings: pairings, credentials: credentials),
            socketFactory: sockets,
            publicAdapterEnabled: true,
            routePinRecorder: pairings
        ))
        let sleeps = PairingTestSleeps()
        let coordinator = HomeClientPairingCoordinator(
            service: service,
            pairings: pairings,
            credentials: credentials,
            configurationStore: configuration,
            claimCoordinator: claims,
            homeClientFactory: bridgeFactory,
            identity: RelayDeviceIdentity(deviceName: "Amanda's iPhone"),
            now: { clock.now },
            sleep: { duration in sleeps.record(duration) }
        )
        return PairingFixture(
            directory: directory,
            clock: clock,
            secure: secure,
            configuration: configuration,
            pairings: pairings,
            credentials: credentials,
            service: service,
            claims: claims,
            sockets: sockets,
            bridgeFactory: bridgeFactory,
            sleeps: sleeps,
            coordinator: coordinator,
            echo: EchoHomeBridgeClientFactory()
        )
    }
}

private struct PairingFixture: Sendable {
    let directory: URL
    let clock: PairingTestClock
    let secure: PairingTestSecureStore
    let configuration: RelayConfigurationStore
    let pairings: JSONHomeClientPairingStore
    let credentials: KeychainHomeCredentialStore
    let service: FakeHomeClientService
    let claims: HomeClientClaimCoordinator
    let sockets: PairingTestSocketFactory
    let bridgeFactory: DefaultHomeBridgeSessionClientFactory
    let sleeps: PairingTestSleeps
    let coordinator: HomeClientPairingCoordinator
    let echo: EchoHomeBridgeClientFactory

    @MainActor
    func makeStore() -> ConversationStore {
        let directory = directory
        return ConversationStore(
            configurationStore: configuration,
            makePersistence: { profileID in
                JSONConversationPersistence(
                    fileURL: ConversationPersistenceFile.url(in: directory, for: profileID)
                )
            },
            homeClientFactory: echo,
            homeClaimProvider: AppHomeConversationClaimProvider(pairedClaims: claims)
        )
    }
}

// MARK: - Test doubles

private final class PairingTestDirectories: @unchecked Sendable {
    static let shared = PairingTestDirectories()
    private let lock = NSLock()
    private var directories: [URL] = []

    func register(_ directory: URL) {
        lock.lock(); defer { lock.unlock() }
        directories.append(directory)
    }

    func removeAll() {
        lock.lock()
        let pending = directories
        directories.removeAll()
        lock.unlock()
        for directory in pending { try? FileManager.default.removeItem(at: directory) }
    }
}

@MainActor
private final class PairingTestCounter {
    var count = 0
}

private final class PairingTestClock: @unchecked Sendable {
    static let start = Date(timeIntervalSince1970: 1_800_000_000)
    private let lock = NSLock()
    private var current = PairingTestClock.start

    var now: Date {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    func advance(by interval: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        current = current.addingTimeInterval(interval)
    }
}

private final class PairingTestSleeps: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Duration] = []
    var onSleep: (@Sendable () -> Void)?

    var recorded: [Duration] {
        lock.lock(); defer { lock.unlock() }
        return values
    }

    func record(_ duration: Duration) {
        lock.lock()
        values.append(duration)
        let hook = onSleep
        lock.unlock()
        hook?()
    }
}

private final class PairingTestSecureStore: SecureValueStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    private let failWrites: Bool

    init(failWrites: Bool = false) {
        self.failWrites = failWrites
    }

    var isEmpty: Bool {
        lock.lock(); defer { lock.unlock() }
        return values.isEmpty
    }

    func value(account: String) -> Data? {
        lock.lock(); defer { lock.unlock() }
        return values["\(HomeCredentialKeychain.service)/\(account)"]
    }

    func valueCount(matching data: Data) -> Int {
        lock.lock(); defer { lock.unlock() }
        return values.values.filter { $0 == data }.count
    }

    func read(service: String, account: String) throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        return values["\(service)/\(account)"]
    }

    func write(_ value: Data, service: String, account: String) throws {
        if failWrites { throw PairingTestError.keychainUnavailable }
        lock.lock(); defer { lock.unlock() }
        values["\(service)/\(account)"] = value
    }

    func delete(service: String, account: String) throws {
        lock.lock(); defer { lock.unlock() }
        values.removeValue(forKey: "\(service)/\(account)")
    }
}

private enum PairingTestError: Error {
    case keychainUnavailable
    case unexpectedMethod
    case closed
}

private func json(_ object: [String: Any]) -> Data {
    try! JSONSerialization.data(withJSONObject: object)
}

private struct FixedPairingRouteProvider: HomeApprovedRouteProvider {
    let route: HomeApprovedRoute?
    func approvedRoute(for profileID: UUID) async throws -> HomeApprovedRoute? { route }
}

private struct RecordedHomeRequest: Sendable {
    let path: String
    let authorization: String?
    let bodyData: Data?

    var body: NSDictionary? {
        guard let bodyData else { return nil }
        return (try? JSONSerialization.jsonObject(with: bodyData)) as? NSDictionary
    }
}

private actor ScriptedHomeTransport: HomeHTTPTransport {
    private var responses: [(Int, Data)] = []
    private(set) var requests: [RecordedHomeRequest] = []

    func enqueue(_ status: Int, _ data: Data) {
        responses.append((status, data))
    }

    func data(for request: URLRequest) async throws -> (Data, HomeHTTPResponse) {
        requests.append(RecordedHomeRequest(
            path: request.url?.path ?? "",
            authorization: request.value(forHTTPHeaderField: "Authorization"),
            bodyData: request.httpBody
        ))
        let (status, data) = responses.removeFirst()
        return (data, HomeHTTPResponse(statusCode: status))
    }
}

/// A minimal Home bridge socket: `conversation.open` names a route, and
/// `conversation.close` ends the claim.
private actor PairingTestSocketFactory: WebSocketConnectionFactory {
    private var readyRouteID: String
    private let openSucceeds: Bool
    private(set) var authorizations: [String] = []
    private(set) var methods: [String] = []

    init(readyRouteID: String, openSucceeds: Bool) {
        self.readyRouteID = readyRouteID
        self.openSucceeds = openSucceeds
    }

    func setReadyRouteID(_ id: String) { readyRouteID = id }

    func record(method: String) { methods.append(method) }

    func open(urlRequest: URLRequest) async throws -> any WebSocketConnection {
        authorizations.append(urlRequest.value(forHTTPHeaderField: "Authorization") ?? "")
        return PairingTestSocket(factory: self, readyRouteID: readyRouteID, openSucceeds: openSucceeds)
    }
}

private actor PairingTestSocket: WebSocketConnection {
    private let factory: PairingTestSocketFactory
    private let readyRouteID: String
    private let openSucceeds: Bool
    private var frames: [WebSocketFrame] = []
    private var receivers: [CheckedContinuation<WebSocketFrame, Error>] = []
    private var closed = false

    init(factory: PairingTestSocketFactory, readyRouteID: String, openSucceeds: Bool) {
        self.factory = factory
        self.readyRouteID = readyRouteID
        self.openSucceeds = openSucceeds
    }

    func send(text: String) async throws {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        let id = try XCTUnwrap(object["id"] as? String)
        let method = try XCTUnwrap(object["method"] as? String)
        let params = object["params"] as? [String: Any] ?? [:]
        let handle = params["conversation_handle"] as? String ?? ""
        await factory.record(method: method)
        let result: [String: Any]
        switch method {
        case "conversation.open":
            result = openSucceeds
                ? [
                    "schema": 1,
                    "status": "ready",
                    "conversation_handle": handle,
                    "route": ["class": "home", "id": readyRouteID],
                    "capabilities": ["commands": ["title"], "heartbeat": true, "timing": "absent", "interrupt": true],
                ]
                : [
                    "schema": 1,
                    "status": "unavailable",
                    "conversation_handle": handle,
                    "reason": "hermes_unavailable",
                ]
        case "conversation.close":
            result = ["schema": 1, "conversation_handle": handle, "status": "closed"]
        default:
            throw PairingTestError.unexpectedMethod
        }
        let response: [String: Any] = ["jsonrpc": "2.0", "schema": 1, "id": id, "result": result]
        enqueue(.text(String(decoding: try JSONSerialization.data(withJSONObject: response), as: UTF8.self)))
    }

    func receive() async throws -> WebSocketFrame {
        if !frames.isEmpty { return frames.removeFirst() }
        if closed { throw PairingTestError.closed }
        return try await withCheckedThrowingContinuation { receivers.append($0) }
    }

    func close() async {
        closed = true
        let waiters = receivers
        receivers.removeAll()
        for waiter in waiters { waiter.resume(throwing: PairingTestError.closed) }
    }

    private func enqueue(_ frame: WebSocketFrame) {
        if receivers.isEmpty {
            frames.append(frame)
        } else {
            receivers.removeFirst().resume(returning: frame)
        }
    }
}

/// Store-level bridge double: opens whatever claim it is given, so each
/// fresh client claim yields a new conversation.
private final class EchoHomeBridgeClientFactory: HomeBridgeSessionClientFactory, @unchecked Sendable {
    private let lock = NSLock()
    private var made: [EchoHomeBridgeClient] = []
    private var ended: Set<String> = []

    var clients: [EchoHomeBridgeClient] {
        lock.lock(); defer { lock.unlock() }
        return made
    }

    /// Home has closed this claim (for example, its reconnect grace passed).
    func end(handle: String) {
        lock.lock(); defer { lock.unlock() }
        ended.insert(handle)
    }

    func isEnded(_ handle: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return ended.contains(handle)
    }

    func make(profileID: UUID, mode: AppleTransportMode) -> any HomeBridgeSessionClient {
        let client = EchoHomeBridgeClient(isEnded: { [weak self] in self?.isEnded($0) ?? false })
        lock.lock()
        made.append(client)
        lock.unlock()
        return client
    }

    func totalConversationCloses() async -> Int {
        var total = 0
        for client in clients { total += await client.conversationCloses }
        return total
    }

    func allSubmittedTexts() async -> [String] {
        var texts: [String] = []
        for client in clients { texts += await client.submittedTexts }
        return texts
    }
}

private actor EchoHomeBridgeClient: HomeBridgeSessionClient {
    private let stream: AsyncThrowingStream<HomeBridgeEvent, Error>
    private let continuation: AsyncThrowingStream<HomeBridgeEvent, Error>.Continuation
    private var binding: HomeConversationBinding?
    private var nextSubmission: HomePromptSubmissionOutcome?
    private var replyText: String?
    private(set) var submittedTexts: [String] = []
    private(set) var conversationCloses = 0
    private var openedHandles: [String] = []
    nonisolated(unsafe) private(set) var openCount = 0
    nonisolated(unsafe) private(set) var openedHandlesSnapshot: [String] = []

    private let isEnded: @Sendable (String) -> Bool

    init(isEnded: @escaping @Sendable (String) -> Bool = { _ in false }) {
        self.isEnded = isEnded
        let pair = AsyncThrowingStream<HomeBridgeEvent, Error>.makeStream()
        stream = pair.stream
        continuation = pair.continuation
    }

    func setNextSubmission(_ outcome: HomePromptSubmissionOutcome) { nextSubmission = outcome }
    func completeNextTurn(with text: String) { replyText = text }
    func lastOpenedHandle() -> String? { openedHandles.last }

    func open(claim: HomeConversationClaim) async -> HomeOpenOutcome {
        openCount += 1
        openedHandles.append(claim.conversationHandle)
        openedHandlesSnapshot = openedHandles
        if isEnded(claim.conversationHandle) {
            return .unavailable(.home(code: .staleConversation, phase: .open))
        }
        let capabilities = HomeBridgeCapabilities(commands: [], heartbeat: true, interrupt: true)
        let binding = HomeConversationBinding(
            profileID: claim.profileID,
            conversationHandle: claim.conversationHandle,
            endpoint: claim.approvedRoute.endpoint,
            route: claim.approvedRoute.identity,
            householdBinding: claim.approvedRoute.householdBinding,
            capabilities: capabilities
        )
        self.binding = binding
        return .ready(binding: binding, capabilities: capabilities)
    }

    func reconnect(binding: HomeConversationBinding) async -> HomeReconnectOutcome {
        .ready(binding: binding, unresolvedTurn: nil, confirmsNoUnresolvedTurn: true)
    }

    func submitPrompt(_ text: String, binding: HomeConversationBinding) async -> HomePromptSubmissionOutcome {
        submittedTexts.append(text)
        if let nextSubmission {
            self.nextSubmission = nil
            return nextSubmission
        }
        let turn = HomeTurnBinding(conversationHandle: binding.conversationHandle, turnID: "turn-\(submittedTexts.count)", correlationID: nil)
        let scope = HomeEventScope(conversationHandle: binding.conversationHandle, turnID: turn.turnID, correlationID: nil)
        if let replyText {
            let continuation = continuation
            Task {
                try? await Task.sleep(for: .milliseconds(20))
                continuation.yield(.standard(HomeStandardEvent(
                    type: .messageStart, scope: scope, payload: .start(kind: .assistant)
                )))
                continuation.yield(.standard(HomeStandardEvent(
                    type: .textDelta, scope: scope,
                    payload: .delta(rendered: nil, text: replyText, replace: false, kind: .assistant)
                )))
                continuation.yield(.standard(HomeStandardEvent(
                    type: .turnComplete, scope: scope, payload: .terminal(kind: nil)
                )))
            }
        }
        return .accepted(turn)
    }

    func interrupt(binding: HomeConversationBinding, turnID: String) async -> HomeInterruptOutcome { .acknowledged }

    func respond(to prompt: HomeStructuredPrompt, with response: HomePromptResponse) async -> HomeStructuredResponseOutcome {
        .accepted
    }

    func dispatch(_ command: HomeCommandRequest) async -> HomeCommandOutcome {
        .rejected(.home(code: .capabilityUnavailable, phase: .command))
    }

    func ping(binding: HomeConversationBinding) async -> HomePingOutcome { .alive }

    func cancelPending(requestID: HomePendingRequestID) async {}

    func events() async -> AsyncThrowingStream<HomeBridgeEvent, Error> { stream }

    func close(binding requested: HomeConversationBinding) async -> HomeConversationCloseOutcome {
        guard binding == requested else {
            return .unavailable(.home(code: .conversationMismatch, phase: .lifecycle))
        }
        conversationCloses += 1
        return .closed
    }

    func close() async {
        continuation.finish()
    }
}
