import Foundation
import Observation

struct AppOption: Codable, Identifiable {
    let id: String
    let label: String
    var isSelected: Bool
}

struct AppOptionsData: Codable {
    let appId: String
    let options: [AppOption]
}

struct AppOptionsResponse: Codable {
    let apps: [String: AppOptionsData]
    
    enum CodingKeys: String, CodingKey {
        case apps
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        apps = try container.decode([String: AppOptionsData].self, forKey: .apps)
    }
}

@Observable
final class AppOptionsService {
    static let shared = AppOptionsService()
    
    private var cachedData: [String: AppOptionsData] = [:]
    private var optionStates: [String: [String: Bool]] = [:] // appId -> optionId -> isSelected
    
    private init() {
        loadData()
    }
    
    func loadData() {
        guard let url = Bundle.main.url(forResource: "app_options", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: AppOptionsData].self, from: data) else {
            return
        }
        cachedData = decoded
        
        // Initialize option states from cached data
        for (appId, appData) in decoded {
            var states: [String: Bool] = [:]
            for option in appData.options {
                states[option.id] = option.isSelected
            }
            optionStates[appId] = states
        }
    }
    
    func getOptions(for appId: String) -> AppOptionsData? {
        return cachedData[appId]
    }
    
    func getSelectedOptions(for appId: String) -> [AppOption] {
        return getAllOptions(for: appId).filter { $0.isSelected }
    }
    
    func getAllOptions(for appId: String) -> [AppOption] {
        guard let appData = cachedData[appId] else { return [] }
        return appData.options.map { option in
            var mutableOption = option
            mutableOption.isSelected = optionStates[appId]?[option.id] ?? option.isSelected
            return mutableOption
        }
    }
    
    func toggleOption(appId: String, optionId: String) {
        if optionStates[appId] == nil {
            optionStates[appId] = [:]
        }
        let currentState = optionStates[appId]?[optionId] ?? false
        optionStates[appId]?[optionId] = !currentState
    }
    
    func isOptionSelected(appId: String, optionId: String) -> Bool {
        return optionStates[appId]?[optionId] ?? false
    }
}
