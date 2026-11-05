//
//  AddSMBView.swift
//  Yattee
//
//  View for adding an SMB (Samba) share as a media source.
//

import SwiftUI

struct AddSMBView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appEnvironment) private var appEnvironment

    // MARK: - State

    @State private var name = ""
    @State private var server = ""
    @State private var username = ""
    @State private var password = ""
    @State private var protocolVersion: SMBProtocol = .auto

    @State private var isTesting = false
    @State private var testResult: SourceTestResult?
    @State private var testProgress: String?

    // Pre-filled from network discovery
    var prefillServer: String?
    var prefillName: String?

    // Closure to dismiss the parent sheet
    var dismissSheet: DismissAction?

    // MARK: - Computed Properties

    private var canAdd: Bool {
        !name.isEmpty && !server.isEmpty
    }

    /// macOS surfaces toolbar confirmation items from a pushed-in-sheet view
    /// reliably only from macOS 26 onward. On older macOS we render the
    /// "Add Source" action button inline in the form instead.
    private var usesToolbarActionButton: Bool {
        return false
    }

    // MARK: - Body

    var body: some View {
        Form {
            nameSection
            serverSection
            authSection
            protocolSection

            if let result = testResult {
                SourceTestResultSection(result: result)
            }

            actionSection
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle(String(localized: "sources.addSMB"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if let prefillServer {
                server = prefillServer
            }
            if let prefillName, name.isEmpty {
                name = prefillName
            }
        }
    }


    // MARK: - Sections

    private var nameSection: some View {
        Section {
            TextField(String(localized: "sources.field.name"), text: $name)
        } footer: {
            Text(String(localized: "sources.footer.displayName"))
        }
    }

    private var serverSection: some View {
        Section {
            TextField(String(localized: "sources.placeholder.smbServer"), text: $server, prompt: Text(String(localized: "sources.placeholder.smbServer")))
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        } footer: {
            Text(String(localized: "sources.footer.smb"))
        }
    }

    private var authSection: some View {
        Section {
            TextField(String(localized: "sources.field.usernameOptional"), text: $username)
                .textContentType(.username)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            SecureField(String(localized: "sources.field.passwordOptional"), text: $password)
                .textContentType(.password)
        } header: {
            Text(String(localized: "sources.header.auth"))
        } footer: {
            Text(String(localized: "sources.footer.auth"))
        }
    }

    private var protocolSection: some View {
        Section {
            Picker(String(localized: "sources.field.smbProtocol"), selection: $protocolVersion) {
                ForEach(SMBProtocol.allCases, id: \.self) { proto in
                    Text(proto.displayName).tag(proto)
                }
            }
        } header: {
            Text(String(localized: "sources.header.advanced"))
        } footer: {
            Text(String(localized: "sources.footer.smbProtocol"))
        }
    }

    private var actionSection: some View {
        Section {
            Button {
                addSource()
            } label: {
                if isTesting {
                    HStack {
                        ProgressView()
                            .controlSize(.small)
                        Text(testProgress ?? String(localized: "sources.testing"))
                    }
                } else {
                    Text(String(localized: "sources.addSource"))
                }
            }
            .disabled(!canAdd || isTesting)
        }
    }

    // MARK: - Actions

    private func addSource() {
        guard let appEnvironment else { return }

        let urlString = "smb://\(server)"
        guard let encodedURLString = urlString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: encodedURLString) else {
            testResult = .failure(String(localized: "sources.error.invalidSMBAddress"))
            return
        }

        isTesting = true
        testResult = nil
        testProgress = String(localized: "sources.testing.connecting")

        let source = MediaSource.smb(
            name: name,
            url: url,
            username: username.isEmpty ? nil : username,
            protocolVersion: protocolVersion
        )

        Task {
            do {
                _ = try await appEnvironment.smbClient.testConnection(
                    source: source,
                    password: password.isEmpty ? nil : password
                )

                await MainActor.run {
                    if !password.isEmpty {
                        appEnvironment.mediaSourcesManager.setPassword(password, for: source)
                    }

                    appEnvironment.mediaSourcesManager.add(source)
                    isTesting = false
                    testProgress = nil
                    if let dismissSheet {
                        dismissSheet()
                    } else {
                        dismiss()
                    }
                }
            } catch {
                await MainActor.run {
                    isTesting = false
                    testProgress = nil
                    testResult = .failure(error.localizedDescription)
                }
            }
        }
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        AddSMBView()
            .appEnvironment(.preview)
    }
}
