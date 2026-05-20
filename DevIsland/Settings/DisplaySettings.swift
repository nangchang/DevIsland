import Foundation

enum RequestDisplayTarget: String, CaseIterable, Identifiable {
    case notch
    case focused
    case mouse

    var id: String { rawValue }

    var label: String {
        let l = L10n.shared
        switch self {
        case .notch:   return l.reqNotch
        case .focused: return l.reqFocused
        case .mouse:   return l.reqMouse
        }
    }
}

enum NotchDisplayTarget: String, CaseIterable, Identifiable {
    case automatic
    case main
    case mouse
    case focused
    case specific

    var id: String { rawValue }

    var label: String {
        let l = L10n.shared
        switch self {
        case .automatic: return l.notchAuto
        case .main:      return l.notchMain
        case .mouse:     return l.notchMouse
        case .focused:   return l.notchFocused
        case .specific:  return l.notchSpecific
        }
    }
}
