import ServiceManagement

/// Start-at-login via the modern SMAppService API (macOS 13+).
/// Only meaningful when running as the .app bundle; calls from a bare
/// binary will throw, which the settings UI surfaces as an error.
enum LaunchAtLogin {
  static var isEnabled: Bool {
    SMAppService.mainApp.status == .enabled
  }

  /// Registered, but switched off under System Settings → General →
  /// Login Items: only the user can turn it back on there.
  static var needsApproval: Bool {
    SMAppService.mainApp.status == .requiresApproval
  }

  static func setEnabled(_ enabled: Bool) throws {
    if enabled {
      try SMAppService.mainApp.register()
    } else {
      try SMAppService.mainApp.unregister()
    }
  }

  /// Bring the login item in line with config.yml (`start_at_login`)
  /// without overriding the user: one switched off in System Settings
  /// stays off rather than being registered again at every launch.
  static func apply(_ enabled: Bool) {
    let status = SMAppService.mainApp.status
    if enabled, status == .notRegistered || status == .notFound {
      try? setEnabled(true)
    } else if !enabled, status == .enabled || status == .requiresApproval {
      try? setEnabled(false)
    }
  }
}
