import Foundation
import Combine

/// Manages the list of radio stations with UserDefaults persistence
@MainActor
final class StationStore: ObservableObject {
    @Published var stations: [RadioStation] = []

    private let storageKey = "island-radio-stations"

    init() {
        load()
    }

    func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([RadioStation].self, from: data) else {
            stations = RadioStation.defaultStations
            return
        }
        stations = decoded
    }

    func save() {
        if let data = try? JSONEncoder().encode(stations) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }

    func add(_ station: RadioStation) {
        stations.append(station)
        save()
    }

    func remove(at offsets: IndexSet) {
        stations.remove(atOffsets: offsets)
        save()
    }

    func update(_ station: RadioStation) {
        if let idx = stations.firstIndex(where: { $0.id == station.id }) {
            stations[idx] = station
            save()
        }
    }
}
