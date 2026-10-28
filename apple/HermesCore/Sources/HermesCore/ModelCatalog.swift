import Foundation

/// Model picker inventory from `GET /api/model/options` (port of `domain/ModelCatalog.kt`,
/// SPEC §12.7): only authenticated providers that list models; the current provider first.
public enum ModelCatalog {
    public struct Group: Equatable, Sendable {
        public let provider: String
        public let name: String
        public let models: [String]
        public let isCurrent: Bool
    }

    public struct Catalog: Equatable, Sendable {
        public let defaultModel: String
        public let defaultProvider: String
        public let groups: [Group]
        public func allModels() -> [String] {
            var seen = Set<String>()
            return groups.flatMap(\.models).filter { seen.insert($0).inserted }
        }
    }

    public static func parse(_ root: JSONObject) -> Catalog {
        let groups: [Group] = (root.array("providers") ?? []).compactMap { el in
            guard let p = el as? JSONObject, p.str("authenticated") == "true", let slug = p.str("slug") else { return nil }
            var seen = Set<String>()
            let models = (p.array("models") ?? []).compactMap { $0 as? String }
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty && seen.insert($0).inserted }
            if models.isEmpty { return nil }
            return Group(provider: slug, name: p.str("name") ?? slug, models: models, isCurrent: p.str("is_current") == "true")
        }
        let ordered: [Group]
        if let i = groups.firstIndex(where: \.isCurrent) {
            var rest = groups
            let cur = rest.remove(at: i)
            ordered = [cur] + rest
        } else {
            ordered = groups
        }
        return Catalog(defaultModel: root.str("model") ?? "", defaultProvider: root.str("provider") ?? "", groups: ordered)
    }

    public static func shortName(_ model: String) -> String {
        String((model.split(separator: "/").last.map(String.init) ?? model).prefix(28))
    }
}
