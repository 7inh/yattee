//
//  SourceBadge.swift
//  Yattee
//
//  Shared rows need no source badge when every source uses Invidious.
//

import Foundation
import SwiftUI

struct SourceBadge: View {
    let source: ContentSource
    var body: some View { EmptyView() }
}
