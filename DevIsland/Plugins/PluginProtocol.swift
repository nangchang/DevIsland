import Foundation

enum PluginKind: String, Codable {
    case coreAware
    case utility
}

struct PluginManifest: Codable, Equatable {
    let id: String
    let name: String
    let version: String
    let apiVersion: Int
    let kind: PluginKind
    let permissions: Set<PluginPermission>
    let surfaces: Set<PluginUISlot>
    let activationEvents: Set<String>
}

protocol DevIslandPlugin: AnyObject {
    var manifest: PluginManifest { get }

    func onEvent(_ event: PluginEvent, context: PluginContext) throws -> [PluginEffect]
    func makeUIContribution(for slot: PluginUISlot, context: PluginUIContext) throws -> PluginUIContribution?
    func needsTick(surfaceState: PluginSurfaceState) -> Bool
}

struct PluginContext: Equatable {
    let pluginID: String
    let permissions: Set<PluginPermission>
    let storageSnapshot: [String: String]
}

struct PluginEffect: Codable, Equatable {
    let capability: String
    let payload: [String: String]
}

