# SwiftLibarchive

SwiftLibarchive 是一个基于 C 语言库 libarchive 封装实现的 Swift 工具类，提供压缩、解压缩和密码检测功能。

## 功能特点

- 支持多种压缩格式（ZIP、TAR、TAR.GZ、7Z等）
- 支持带密码的压缩和解压缩
- 提供检测压缩包是否需要密码的方法
- 简单易用的 Swift API

## 使用方法

### 导入模块

```swift
import SwiftLibarchive
```

### 压缩文件或目录

```swift
do {
    // 不带密码压缩
    try SwiftLibarchive.shared.compress(sourcePath: "/path/to/source", 
                                       to: "/path/to/archive.zip", 
                                       format: .zip)
    
    // 带密码压缩
    try SwiftLibarchive.shared.compress(sourcePath: "/path/to/source", 
                                       to: "/path/to/archive_with_password.zip", 
                                       format: .zip, 
                                       password: "your_password")
} catch {
    print("压缩失败: \(error)")
}
```

### 解压缩文件

```swift
do {
    // 不带密码解压
    try SwiftLibarchive.shared.extract(archivePath: "/path/to/archive.zip", 
                                     to: "/path/to/destination")
    
    // 带密码解压
    try SwiftLibarchive.shared.extract(archivePath: "/path/to/archive_with_password.zip", 
                                     to: "/path/to/destination", 
                                     password: "your_password")
} catch {
    print("解压失败: \(error)")
}
```

### 检测压缩包是否需要密码

```swift
do {
    let needsPassword = try SwiftLibarchive.shared.isPasswordRequired(archivePath: "/path/to/archive.zip")
    
    if needsPassword {
        print("压缩包需要密码")
    } else {
        print("压缩包不需要密码")
    }
} catch {
    print("检测失败: \(error)")
}
```

## 错误处理

SwiftLibarchive 定义了以下错误类型：

```swift
public enum ArchiveError: Error {
    case createArchiveFailed
    case openFileFailed
    case readEntryFailed
    case extractFailed
    case compressFailed
    case passwordRequired
    case wrongPassword
    case unsupportedFormat
    case unknownError(String)
}
```

可以通过 catch 语句捕获并处理这些错误：

```swift
do {
    try SwiftLibarchive.shared.extract(archivePath: "/path/to/archive.zip", 
                                     to: "/path/to/destination")
} catch let error as SwiftLibarchive.ArchiveError {
    switch error {
    case .passwordRequired:
        print("需要密码才能解压")
    case .wrongPassword:
        print("密码错误")
    case .openFileFailed:
        print("打开文件失败")
    case .readEntryFailed:
        print("读取条目失败")
    case .extractFailed:
        print("解压过程失败")
    default:
        print("解压失败: \(error)")
    }
} catch {
    print("未知错误: \(error)")
}
```

## 许可证

本项目采用 MIT 许可证。详情请参阅 [LICENSE](LICENSE) 文件。