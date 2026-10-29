//
//  FakeAPIClient.swift
//  BetterBlueKit
//
//  SwiftData-based Fake API Client for Testing and Development
//

import Foundation

// MARK: - Fake API Client

@MainActor
public class FakeAPIClient: APIClientProtocol {
    private let region: Region
    private let username: String
    private let password: String
    private let pin: String
    private let accountId: UUID
    private let vehicleProvider: FakeVehicleProvider

    public init(
        configuration: APIClientConfiguration,
        vehicleProvider: FakeVehicleProvider,
    ) {
        region = configuration.region
        username = configuration.username
        password = configuration.password
        pin = configuration.pin
        accountId = configuration.accountId
        self.vehicleProvider = vehicleProvider

        BBLogger.info(.fakeAPI, "Initialized for user '\(configuration.username)' with custom vehicle provider")
    }

    // MARK: - APIClientProtocol Implementation

    public func login() async throws -> AuthToken {
        // Check for debug credential validation failure across all fake vehicles for this account
        if try await vehicleProvider.shouldFailCredentialValidation(accountId: accountId) {
            BBLogger.warning(.fakeAPI, "Debug: Simulating credential validation failure")
            let message = try await vehicleProvider.getCustomCredentialErrorMessage(accountId: accountId)
            throw APIError.invalidCredentials(message, apiName: "FakeAPI")
        }

        // Check for debug login failure
        if try await vehicleProvider.shouldFailLogin(accountId: accountId) {
            BBLogger.warning(.fakeAPI, "Debug: Simulating login failure")
            throw APIError.logError("Debug: Simulated login failure", code: 500, apiName: "FakeAPI")
        }

        BBLogger.info(.fakeAPI, "Login successful for user '\(username)'")
        return AuthToken(
            accessToken: "fake_access_token_\(UUID().uuidString)",
            refreshToken: "fake_refresh_token_\(UUID().uuidString)",
            expiresAt: Date().addingTimeInterval(3600)
        )
    }

    public func fetchVehicles(authToken _: AuthToken) async throws -> [Vehicle] {
        // Check for debug vehicle fetch failure
        if try await vehicleProvider.shouldFailVehicleFetch(accountId: accountId) {
            BBLogger.warning(.fakeAPI, "Debug: Simulating vehicle fetch failure")
            throw APIError.logError("Debug: Simulated vehicle fetch failure", code: 500, apiName: "FakeAPI")
        }

        BBLogger.info(.fakeAPI, "Fetching vehicles for user '\(username)'...")
        let vehicles = try await vehicleProvider.getFakeVehicles(for: username, accountId: accountId)
        let vinsList = vehicles.map(\.vin).joined(separator: ", ")
        BBLogger.info(
            .fakeAPI,
            "Fetched \(vehicles.count) fake vehicles for user '\(username)': [\(vinsList)]"
        )
        return vehicles
    }

    public func fetchVehicleStatus(
        for vehicle: Vehicle,
        authToken _: AuthToken,
        cached: Bool
    ) async throws -> VehicleStatus {
        // Check for debug status fetch failure
        if try await vehicleProvider.shouldFailStatusFetch(for: vehicle.vin, accountId: accountId) {
            BBLogger.warning(.fakeAPI, "Debug: Simulating status fetch failure")
            throw APIError.logError("Debug: Simulated status fetch failure", code: 500, apiName: "FakeAPI")
        }

        let status = try await vehicleProvider.getVehicleStatus(for: vehicle.vin, accountId: accountId)
        BBLogger.info(.fakeAPI, "Fetched vehicle status for fake vehicle '\(vehicle.vin)' (cached: \(cached))")
        return status
    }

    public func fetchEVTripDetails(for vehicle: Vehicle, authToken _: AuthToken) async throws -> [EVTripDetail]? {
        // Test account: generate seven days of synthetic trips so the Trip History sheet
        // has something realistic to render. Pattern is a daily commute + weekend road trip,
        // sized to give the energy-breakdown bars visible variation. Skips when the fake
        // vehicle isn't electric — same gate the real Hyundai client uses.
        // Each trip starts at a fixed hour on its day, so repeated fetches return the
        // same trips (and trip-archive keys) and only a new day brings new ones.
        guard vehicle.fuelType.hasElectricCapability else { return nil }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let template: [(distance: Double, durationMin: Int, totalWh: Int, regenWh: Int, climateWh: Int, drivetrainWh: Int, startHour: Int)] = [
            (28.4, 45, 8_950, 1_140, 720, 6_950, 8),
            (12.1, 24, 3_820, 380, 240, 3_010, 17),
            (46.7, 72, 14_120, 2_010, 980, 10_640, 7),
            (8.3, 18, 2_710, 220, 410, 1_950, 12),
            (35.6, 58, 11_330, 1_540, 880, 8_410, 8),
            (19.2, 31, 6_120, 690, 410, 4_710, 18),
            (112.5, 165, 33_980, 4_120, 2_140, 26_540, 10)
        ]
        let baseOdometer: Double = 12_345
        return template.enumerated().map { (offset, t) -> EVTripDetail in
            let remainder = template.dropFirst(offset + 1).map(\.distance).reduce(0, +)
            let avg = t.durationMin > 0 ? t.distance / (Double(t.durationMin) / 60.0) : 0
            let tripDay = calendar.date(byAdding: .day, value: -(offset + 1), to: today) ?? today
            let startDate = calendar.date(bySettingHour: t.startHour, minute: 0, second: 0, of: tripDay) ?? tripDay
            return EVTripDetail(
                distance: t.distance,
                odometer: baseOdometer + remainder,
                accessoriesEnergy: Int(Double(t.totalWh) * 0.04),
                totalEnergyUsed: t.totalWh,
                regenEnergy: t.regenWh,
                climateEnergy: t.climateWh,
                drivetrainEnergy: t.drivetrainWh,
                batteryCareEnergy: Int(Double(t.totalWh) * 0.02),
                startDate: startDate,
                durationSeconds: t.durationMin * 60,
                avgSpeed: avg,
                maxSpeed: avg + 18.0
            )
        }
    }

    public func sendCommand(for vehicle: Vehicle, command: VehicleCommand, authToken _: AuthToken) async throws {
        // Check for debug PIN validation failure
        if try await vehicleProvider.shouldFailPinValidation(for: vehicle.vin, accountId: accountId) {
            BBLogger.warning(.fakeAPI, "Debug: Simulating PIN validation failure")
            let errorMessage = try await vehicleProvider.getCustomPinErrorMessage(
                for: vehicle.vin,
                accountId: accountId,
            )
            throw APIError.invalidPin(errorMessage, apiName: "FakeAPI")
        }

        // Check for debug command-specific failures
        if try await vehicleProvider.shouldFailCommand(command, for: vehicle.vin, accountId: accountId) {
            let commandName = String(describing: command).components(separatedBy: "(").first ?? "command"
            BBLogger.warning(.fakeAPI, "Debug: Simulating \(commandName) failure")
            throw APIError.logError("Debug: Simulated \(commandName) failure", code: 500, apiName: "FakeAPI")
        }

        try await vehicleProvider.executeCommand(command, for: vehicle.vin, accountId: accountId)
        BBLogger.info(.fakeAPI, "Command completed successfully for fake vehicle '\(vehicle.vin)'")
    }
}

// MARK: - Vehicle Provider Protocol

@MainActor
public protocol FakeVehicleProvider {
    func getFakeVehicles(for username: String, accountId: UUID) async throws -> [Vehicle]
    func getVehicleStatus(for vin: String, accountId: UUID) async throws -> VehicleStatus
    func executeCommand(_ command: VehicleCommand, for vin: String, accountId: UUID) async throws

    // Debug configuration checks
    func shouldFailCredentialValidation(accountId: UUID) async throws -> Bool
    func shouldFailLogin(accountId: UUID) async throws -> Bool
    func shouldFailVehicleFetch(accountId: UUID) async throws -> Bool
    func shouldFailStatusFetch(for vin: String, accountId: UUID) async throws -> Bool
    func shouldFailPinValidation(for vin: String, accountId: UUID) async throws -> Bool
    func shouldFailCommand(_ command: VehicleCommand, for vin: String, accountId: UUID) async throws -> Bool
    func getCustomCredentialErrorMessage(accountId: UUID) async throws -> String
    func getCustomPinErrorMessage(for vin: String, accountId: UUID) async throws -> String
}
