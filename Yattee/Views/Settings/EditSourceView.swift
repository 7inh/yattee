//
//  EditSourceView.swift
//  Yattee
//
//  Invidious settings and account sign-in.
//

import Foundation
import SwiftUI

struct EditSourceView: View {
    let source: UnifiedSource
    var body: some View {
        switch source {
        case .remoteServer(let instance): EditInvidiousSourceView(instance: instance)
        }
    }
}

private struct EditInvidiousSourceView: View {
    let instance: Instance
    @Environment(\.appEnvironment) private var appEnvironment
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var isEnabled: Bool
    @State private var proxiesAudio: Bool
    @State private var allowInvalidCertificates: Bool
    @State private var username = ""
    @State private var password = ""
    @State private var loginTarget: AccountLoginTarget?

    init(instance: Instance) {
        self.instance = instance
        _name = State(initialValue: instance.name ?? "")
        _isEnabled = State(initialValue: instance.isEnabled)
        _proxiesAudio = State(initialValue: instance.proxiesVideos)
        _allowInvalidCertificates = State(initialValue: instance.allowInvalidCertificates)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Invidious") {
                    Text(instance.url.absoluteString).textSelection(.enabled)
                    TextField("Name", text: $name)
                    Toggle("Enabled", isOn: $isEnabled)
                    Toggle("Proxy audio through this instance", isOn: $proxiesAudio)
                    Toggle("Allow invalid certificates", isOn: $allowInvalidCertificates)
                }
                Section("HTTP Basic Auth") {
                    TextField("Username", text: $username).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("Password", text: $password)
                }
                InstanceAccountsSection(instance: instance, loginTarget: $loginTarget)
            }
            .navigationTitle(instance.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                sheetCloseToolbarItem { dismiss() }
                ToolbarItem(placement: .confirmationAction) { Button("Save", action: save) }
            }
        }
        .task {
            if let credentials = appEnvironment?.basicAuthCredentialsManager.credentials(for: instance) {
                username = credentials.username
                password = credentials.password
            }
        }
        .sheet(item: $loginTarget) { target in
            InstanceLoginView(instance: instance, initialUsername: target.account.flatMap {
                appEnvironment?.accountCredentialsManager(for: $0)?.username(for: $0)
            }) { credential, username in
                guard let appEnvironment else { return false }
                return AccountSignInHandler(appEnvironment: appEnvironment, instance: instance)
                    .storeLogin(credential: credential, username: username, target: target)
            }
        }
    }

    private func save() {
        guard let appEnvironment else { return }
        var updated = appEnvironment.instancesManager.instances.first { $0.id == instance.id } ?? instance
        updated.name = name.isEmpty ? nil : name
        updated.isEnabled = isEnabled
        updated.proxiesVideos = proxiesAudio
        updated.allowInvalidCertificates = allowInvalidCertificates
        updated.usesBasicAuth = !username.isEmpty
        if username.isEmpty { appEnvironment.basicAuthCredentialsManager.deleteCredentials(for: instance) }
        else { appEnvironment.basicAuthCredentialsManager.setCredentials(username: username, password: password, for: instance) }
        appEnvironment.instancesManager.update(updated)
        dismiss()
    }
}
