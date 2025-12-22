//
//  ContentView.swift
//  Example
//
//  Created by xxs on 2025/12/19.
//

import SwiftUI
import SwiftLibarchive

struct ContentView: View {
    var body: some View {
        VStack {
            Button {
                compress()
            } label: {
                Text("unzip")
            }
        }
        .padding()
    }
}

extension ContentView {
    func compress() {
        guard let url = Bundle.main.url(forResource: "video", withExtension: "zip") else { return }
//        SwiftLibarchive.shared.compressAsync(sourcePath: <#T##String#>, to: <#T##String#>, format: <#T##SwiftLibarchive.ArchiveFormat#>, completion: <#T##SwiftLibarchive.CompletionCallback##SwiftLibarchive.CompletionCallback##(Result<Void, SwiftLibarchive.ArchiveError>) -> Void#>)
    }
}
