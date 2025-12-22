//
//  ContentView.swift
//  Example
//
//  Created by xxs on 2025/12/19.
//

import SwiftUI
import SwiftLibarchive

struct ContentView: View {
    @State private var unzipProgress: Float = 0
    @State private var zipProgress: Float = 0
    @State private var extractTask: UUID?
    @State private var compressTask: UUID?
    @State private var compressT: Task<(), Never>?

    var body: some View {
        VStack {
            ProgressView("unzip progress: ", value: unzipProgress)
            HStack {
                Button {
                    extract()
                } label: {
                    Text("unzip")
                }
                Button {
                    cancelExtract()
                } label: {
                    Text("cancel unzip")
                }
            }

            ProgressView("zip progress: ", value: zipProgress)
            HStack {
                Button {
                    compress()
                } label: {
                    Text("zip")
                }
                Button {
                    cancelCompress()
                } label: {
                    Text("cancel zip")
                }
            }

            Button {
                NSWorkspace.shared.open(URL.temporaryDirectory)
            } label: {
                Text("打开缓存路径")
            }

        }
        .padding()
        .onAppear {
            guard let readme = Bundle.main.url(forResource: "README", withExtension: "md"),
                  let license = Bundle.main.url(forResource: "LICENSE", withExtension: "") else { return }
            let temp = URL.temporaryDirectory.appendingPathComponent("source")
            if !FileManager.default.fileExists(atPath: temp.path) {
                try? FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
            }
            let readmePath = temp.appendingPathComponent("README.md")
            let licensePath = temp.appendingPathComponent("LICENSE")
            if !FileManager.default.fileExists(atPath: readmePath.path) {
                try? FileManager.default.copyItem(at: readme, to: readmePath)
            }
            if !FileManager.default.fileExists(atPath: licensePath.path) {
                try? FileManager.default.copyItem(at: license, to: licensePath)
            }
            print("---- temp: \(temp)")
        }
    }
}

extension ContentView {
    func extract() {
        guard let url = Bundle.main.path(forResource: "video", ofType: "zip") else { return }
        let savePath = URL.temporaryDirectory.path
        print("---- savePath: \(savePath)")
        Task {
            extractTask = SwiftLibarchive.shared.extract(archivePath: url, to: savePath, progress: { progress in
                print("---- progress: \(progress)")
                unzipProgress = progress
            }, completion: { result in
                switch result {
                case .success:
                    print("---- success")
                case .failure(let error):
                    print("----- error: \(error.localizedDescription)")
                }
            })
            print("---- taskId: \(extractTask)")
        }
    }

    func cancelExtract() {
        guard let taskId = extractTask else { return }
        SwiftLibarchive.shared.cancelExtract(taskId: taskId)
    }

    func compress() {
        let savePath = URL.temporaryDirectory.path + "/source.zip"
        print("---- savePath: \(savePath)")
        Task {
            guard let source = await pickerFolder() else { return }
            compressTask = SwiftLibarchive.shared.compress(sourcePath: source.path, to: savePath, format: .zip(nil), progress: { progress in
                print("---- progress: \(progress)")
                zipProgress = progress
            }) { result in
                switch result {
                case .success:
                    print("---- success")
                case .failure(let error):
                    print("----- error: \(error.localizedDescription)")
                }
            }
        }
    }

    func cancelCompress() {
        print("---- cancel task 1")
        guard let taskId = compressTask else { return }
        SwiftLibarchive.shared.cancelCompress(taskId: taskId)
//        compressT?.cancel()
        print("---- cancel task 2: \(taskId)")
    }

    func pickerFolder() async -> URL? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        return await withCheckedContinuation { continuation in
            panel.beginSheetModal(for: NSApp.keyWindow!) { result in
                if result == .OK, let url = panel.url {
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }
}
