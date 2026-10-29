//
//  FakeAPIClientTests.swift
//  BetterBlueKit
//
//  Test-account client tests
//

import Foundation
import Testing
@testable import BetterBlueKit

@Suite("Fake API Client Tests")
@MainActor
struct FakeAPIClientTests {

    private struct Unsupported: Error {}

    /// The trip fetch never reaches the provider, so nothing here is implemented.
    private struct NoVehicles: FakeVehicleProvider {
        func getFakeVehicles(for _: String, accountId _: UUID) async throws -> [Vehicle] { [] }
        func getVehicleStatus(for _: String, accountId _: UUID) async throws -> VehicleStatus {
            throw Unsupported()
        }
        func executeCommand(_: VehicleCommand, for _: String, accountId _: UUID) async throws {}
        func shouldFailCredentialValidation(accountId _: UUID) async throws -> Bool { false }
        func shouldFailLogin(accountId _: UUID) async throws -> Bool { false }
        func shouldFailVehicleFetch(accountId _: UUID) async throws -> Bool { false }
        func shouldFailStatusFetch(for _: String, accountId _: UUID) async throws -> Bool { false }
        func shouldFailPinValidation(for _: String, accountId _: UUID) async throws -> Bool { false }
        func shouldFailCommand(_: VehicleCommand, for _: String, accountId _: UUID) async throws -> Bool { false }
        func getCustomCredentialErrorMessage(accountId _: UUID) async throws -> String { "" }
        func getCustomPinErrorMessage(for _: String, accountId _: UUID) async throws -> String { "" }
    }

    private func makeClient() -> FakeAPIClient {
        let config = APIClientConfiguration(
            region: .usa,
            brand: .fake,
            username: "testaccount@betterblue.com",
            password: "betterblue",
            pin: "1234",
            accountId: UUID()
        )
        return FakeAPIClient(configuration: config, vehicleProvider: NoVehicles())
    }

    private func vehicle(fuelType: FuelType) -> Vehicle {
        Vehicle(
            vin: "FAKE-Hyundai IONIQ 5-200",
            regId: "REG200",
            model: "Hyundai IONIQ 5",
            accountId: UUID(),
            fuelType: fuelType,
            generation: 3,
            odometer: Distance(length: 12_345, units: .miles)
        )
    }

    private let token = AuthToken(accessToken: "access", refreshToken: "refresh", expiresAt: Date().addingTimeInterval(3600))

    @Test("Synthetic trips are the same on every fetch")
    func testTripsAreStableAcrossFetches() async throws {
        let client = makeClient()
        let ioniq = vehicle(fuelType: .electric)
        let first = try #require(try await client.fetchEVTripDetails(for: ioniq, authToken: token))
        let second = try #require(try await client.fetchEVTripDetails(for: ioniq, authToken: token))

        // The app's trip archive keys trips by VIN, whole start second and odometer.
        func keys(_ trips: [EVTripDetail]) -> [String] {
            trips.map { "\(ioniq.vin)-\(Int($0.startDate.timeIntervalSince1970))-\($0.odometer)" }
        }
        #expect(first.count == 7)
        #expect(keys(first) == keys(second))
        #expect(first == second)
    }

    @Test("Each synthetic trip starts on the hour, one day further back")
    func testTripsStartOnTheHourOnTheirDay() async throws {
        let trips = try #require(try await makeClient().fetchEVTripDetails(
            for: vehicle(fuelType: .electric),
            authToken: token
        ))
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        for (offset, trip) in trips.enumerated() {
            let tripDay = calendar.startOfDay(for: trip.startDate)
            #expect(calendar.dateComponents([.day], from: tripDay, to: today).day == offset + 1)
            let time = calendar.dateComponents([.minute, .second], from: trip.startDate)
            #expect(time.minute == 0 && time.second == 0)
        }
        #expect(calendar.component(.hour, from: trips[0].startDate) == 8)
        #expect(trips[0].odometer == 12_345 + trips.dropFirst().map(\.distance).reduce(0, +))
    }

    @Test("Gas cars have no synthetic trips")
    func testNoTripsForGasCars() async throws {
        let trips = try await makeClient().fetchEVTripDetails(for: vehicle(fuelType: .gas), authToken: token)
        #expect(trips == nil)
    }
}
