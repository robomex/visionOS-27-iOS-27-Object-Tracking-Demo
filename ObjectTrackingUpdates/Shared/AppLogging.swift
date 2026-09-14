//
//  AppLogging.swift
//  ObjectTrackingUpdates
//

/// One subsystem for every log line the app emits, so `log stream
/// --subsystem` on a device needs one filter. The `PeerConnection` package
/// logs under its own subsystem.
enum AppLogging {
    static let subsystem = "com.example.ObjectTrackingUpdates"
}
