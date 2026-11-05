//
//  AddRemoteServerView.swift
//  Yattee
//
//  Adds an Invidious instance and optional reverse-proxy credentials.
//

import Foundation
import SwiftUI

struct AddRemoteServerView: View {
    let dismissSheet: DismissAction
    @Environment(\.appEnvironment) private var appEnvironment
    @State private var urlString = ""
    @State private var name = ""
    @State private var username = ""
    @State private var password = ""
    @State private var proxiesAudio = true
    @State private var allowInvalidCertificates = false

    var body: some View {
        Form {
            Section("Invidious") {
                TextField("Instance URL", text: $urlString).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                TextField("Name", text: $name)
                Toggle("Proxy audio through this instance", isOn: $proxiesAudio)
                Toggle("Allow invalid certificates", isOn: $allowInvalidCertificates)
            }
            Section("HTTP Basic Auth") {
                TextField("Username", text: $username).textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField("Password", text: $password)
            }
            Button("Add Invidious instance") {
                guard let appEnvironment, let url = Instance.validateURL(urlString) else { return }
                let instance = Instance(type: .invidious, url: url, name: name.isEmpty ? nil : name,
                    allowInvalidCertificates: allowInvalidCertificates, proxiesVideos: proxiesAudio, usesBasicAuth: !username.isEmpty)
                appEnvironment.instancesManager.add(instance)
                if !username.isEmpty {
                    appEnvironment.basicAuthCredentialsManager.setCredentials(username: username, password: password, for: instance)
                }
                dismissSheet()
            }
            .disabled(Instance.validateURL(urlString) == nil)
        }
        .navigationTitle("Add Invidious")
        .navigationBarTitleDisplayMode(.inline)
    }
}
