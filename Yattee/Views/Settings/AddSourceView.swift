//
//  AddSourceView.swift
//  Yattee
//
//  Add an Invidious instance.
//

import Foundation
import SwiftUI

struct AddSourceView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            AddRemoteServerView(dismissSheet: dismiss)
                .toolbar { sheetCloseToolbarItem { dismiss() } }
        }
    }
}
