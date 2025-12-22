import Foundation
import CLibarchive

/// SwiftLibarchive是一个基于libarchive的Swift封装工具类，提供压缩、解压缩和密码检测功能
/// 支持同步和异步操作，以及进度回调和取消功能
public class SwiftLibarchive {
    
    /// 错误类型定义
    public enum ArchiveError: Error, Equatable {
        case createArchiveFailed
        case openFileFailed
        case readEntryFailed
        case extractFailed
        case compressFailed
        case passwordRequired
        case wrongPassword
        case unsupportedFormat
        case operationCancelled
        case unknownError(String)
        
        public static func == (lhs: ArchiveError, rhs: ArchiveError) -> Bool {
            switch (lhs, rhs) {
            case (.createArchiveFailed, .createArchiveFailed),
                 (.openFileFailed, .openFileFailed),
                 (.readEntryFailed, .readEntryFailed),
                 (.extractFailed, .extractFailed),
                 (.compressFailed, .compressFailed),
                 (.passwordRequired, .passwordRequired),
                 (.wrongPassword, .wrongPassword),
                 (.unsupportedFormat, .unsupportedFormat),
                 (.operationCancelled, .operationCancelled):
                return true
            case (.unknownError(let lhsMessage), .unknownError(let rhsMessage)):
                return lhsMessage == rhsMessage
            default:
                return false
            }
        }

        var localizedDescription: String {
            switch self {
            case .createArchiveFailed: return "Failed to create archive."
            case .openFileFailed: return "Failed to open file."
            case .readEntryFailed: return "Failed to read entry."
            case .extractFailed: return "Failed to extract."
            case .compressFailed: return "Failed to compress."
            case .passwordRequired: return "Password is required."
            case .wrongPassword: return "Wrong password."
            case .unsupportedFormat: return "Unsupported format."
            case .operationCancelled: return "Operation cancelled."
            case .unknownError(let message): return "Unknown error: \(message)"
            }
        }
    }
    
    /// 进度回调类型
    public typealias ProgressCallback = (Float) -> Void
    
    /// 完成回调类型
    public typealias CompletionCallback = (Result<Void, ArchiveError>) -> Void
    
    /// 压缩格式
    public enum ArchiveFormat {
        case zip(_ password: String? = nil)
        case tar
        case tarGzip
        case tarBzip2
        case tarXz
        case zip7(_ password: String? = nil)
        case bzip2
        case xz
        case gzip
    }
    
    /// 单例实例
    public static let shared = SwiftLibarchive()
    
    /// 任务输出类型
    private enum TaskOutputType {
        case none
        case extract
        case compress
    }
    
    /// 任务状态
    private struct TaskState {
        var isCancelled: Bool
        var cancelFlag: UnsafeMutablePointer<Int32>?
        var outputPath: String?
        var outputType: TaskOutputType
        var createdDestination: Bool
    }
    
    /// 活动任务管理
    private var activeTasks: [UUID: TaskState] = [:]
    private let taskLock = NSLock()
    
    /// 私有初始化方法
    private init() {}
    
    /// 创建新任务ID
    private func createTask(outputPath: String?, outputType: TaskOutputType, createdDestination: Bool) -> UUID {
        let taskId = UUID()
        let cancelFlag = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
        cancelFlag.initialize(to: 0)
        
        taskLock.lock()
        activeTasks[taskId] = TaskState(
            isCancelled: false,
            cancelFlag: cancelFlag,
            outputPath: outputPath,
            outputType: outputType,
            createdDestination: createdDestination
        )
        taskLock.unlock()
        return taskId
    }
    
    /// 标记任务为已取消
    private func cancelTask(_ taskId: UUID) {
        taskLock.lock()
        if var state = activeTasks[taskId] {
            state.isCancelled = true
            state.cancelFlag?.pointee = 1
            #if DEBUG
            if let ptr = state.cancelFlag {
                fputs("[cancel_flag] Swift cancelTask set flag to \(ptr.pointee) for task \(taskId)\n", stderr)
            } else {
                fputs("[cancel_flag] Swift cancelTask found nil flag for task \(taskId)\n", stderr)
            }
            #endif
            activeTasks[taskId] = state
        }
        taskLock.unlock()
    }
    
    /// 检查任务是否已取消
    private func isTaskCancelled(_ taskId: UUID) -> Bool {
        taskLock.lock()
        defer { taskLock.unlock() }
        return activeTasks[taskId]?.isCancelled ?? false
    }
    
    /// 移除任务
    private func removeTask(_ taskId: UUID) {
        taskLock.lock()
        if let state = activeTasks.removeValue(forKey: taskId) {
            state.cancelFlag?.deinitialize(count: 1)
            state.cancelFlag?.deallocate()
        }
        taskLock.unlock()
    }
    
    /// 取消后清理已生成的输出
    private func cleanupOutputIfNeeded(_ taskId: UUID) {
        taskLock.lock()
        guard let state = activeTasks[taskId] else {
            taskLock.unlock()
            return
        }
        taskLock.unlock()
        
        guard let path = state.outputPath else { return }
        let fm = FileManager.default
        
        switch state.outputType {
        case .none:
            break
        case .extract:
            // 仅在本次操作创建的目录时清理，避免误删用户已有目录
            if state.createdDestination {
                try? fm.removeItem(atPath: path)
            }
        case .compress:
            // 删除已生成的压缩包文件
            if fm.fileExists(atPath: path) {
                try? fm.removeItem(atPath: path)
            }
        }
    }
    
    /// 获取对应任务的取消标记指针
    private func cancelPointer(for taskId: UUID) -> UnsafeMutablePointer<Int32>? {
        taskLock.lock()
        defer { taskLock.unlock() }
        return activeTasks[taskId]?.cancelFlag
    }
    
    /// 解压缩文件（同步方法）
    /// - Parameters:
    ///   - archivePath: 压缩包路径
    ///   - destinationPath: 解压目标路径
    ///   - password: 解压密码（如果需要）
    /// - Throws: 解压过程中的错误
    public func extract(archivePath: String, to destinationPath: String, password: String? = nil, cancelFlag: UnsafeMutablePointer<Int32>? = nil) throws {
        // 实现将在C函数中完成
        let result = extractArchive(archivePath, destinationPath, password, cancelFlag)
        
        if result != 0 {
            switch result {
            case ERROR_PASSWORD_REQUIRED:
                throw ArchiveError.passwordRequired
            case ERROR_WRONG_PASSWORD:
                throw ArchiveError.wrongPassword
            case ERROR_OPEN_FILE_FAILED:
                throw ArchiveError.openFileFailed
            case ERROR_READ_ENTRY_FAILED:
                throw ArchiveError.readEntryFailed
            case ERROR_EXTRACT_FAILED:
                throw ArchiveError.extractFailed
            case ERROR_OPERATION_CANCELLED:
                throw ArchiveError.operationCancelled
            default:
                throw ArchiveError.unknownError("Unknown error code: \(result)")
            }
        }
    }
    
    /// 异步解压缩文件
    /// - Parameters:
    ///   - archivePath: 压缩包路径
    ///   - destinationPath: 解压目标路径
    ///   - password: 解压密码（如果需要）
    ///   - progress: 进度回调
    ///   - completion: 完成回调
    /// - Returns: 任务ID，可用于取消操作
    @discardableResult
    public func extract(archivePath: String, to destinationPath: String, password: String? = nil, progress: ProgressCallback? = nil, completion: @escaping CompletionCallback) -> UUID {
        let destinationExists = FileManager.default.fileExists(atPath: destinationPath)
        let taskId = createTask(outputPath: destinationPath, outputType: .extract, createdDestination: !destinationExists)
        let cancelFlag = cancelPointer(for: taskId)
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else {
                completion(.failure(.unknownError("Self is nil")))
                return
            }
            
            // 模拟进度更新
            var currentProgress: Float = 0.0
            let progressTimer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
            
            progressTimer.setEventHandler { [weak self] in
                guard let self = self, !self.isTaskCancelled(taskId) else {
                    progressTimer.cancel()
                    return
                }
                
                // 增加进度，最大到0.95（留5%给最终处理）
                if currentProgress < 0.95 {
                    currentProgress += 0.05
                    DispatchQueue.main.async {
                        progress?(currentProgress)
                    }
                }
            }
            
            progressTimer.schedule(deadline: .now(), repeating: .milliseconds(200))
            progressTimer.resume()
            
            do {
                // 检查任务是否已取消
                if self.isTaskCancelled(taskId) {
                    progressTimer.cancel()
                    DispatchQueue.main.async {
                        completion(.failure(.operationCancelled))
                    }
                    self.cleanupOutputIfNeeded(taskId)
                    self.removeTask(taskId)
                    return
                }
                
                // 执行解压操作
                try self.extract(archivePath: archivePath, to: destinationPath, password: password, cancelFlag: cancelFlag)
                
                // 检查任务是否已取消
                if self.isTaskCancelled(taskId) {
                    progressTimer.cancel()
                    DispatchQueue.main.async {
                        completion(.failure(.operationCancelled))
                    }
                    self.cleanupOutputIfNeeded(taskId)
                    self.removeTask(taskId)
                    return
                }
                
                // 完成进度
                progressTimer.cancel()
                DispatchQueue.main.async {
                    progress?(1.0)
                    completion(.success(()))
                }
            } catch {
                progressTimer.cancel()
                DispatchQueue.main.async {
                    if self.isTaskCancelled(taskId) {
                        completion(.failure(.operationCancelled))
                        self.cleanupOutputIfNeeded(taskId)
                    } else if let archiveError = error as? ArchiveError {
                        if archiveError == .operationCancelled {
                            self.cleanupOutputIfNeeded(taskId)
                        }
                        completion(.failure(archiveError))
                    } else {
                        completion(.failure(.unknownError(error.localizedDescription)))
                    }
                }
            }
            self.removeTask(taskId)
        }
        
        return taskId
    }

    /// 取消解压任务
    /// - Parameter taskId: 任务ID
    public func cancelExtract(taskId: UUID) {
        cancelTask(taskId)
    }
    
    /// 压缩文件或目录（同步方法）
    /// - Parameters:
    ///   - sourcePath: 源文件或目录路径
    ///   - archivePath: 目标压缩包路径
    ///   - format: 压缩格式
    ///   - password: 压缩密码（如果需要）
    /// - Throws: 压缩过程中的错误
    public func compress(sourcePath: String, to archivePath: String, format: ArchiveFormat, cancelFlag: UnsafeMutablePointer<Int32>? = nil) throws {
        // 将枚举转换为对应的格式值
        let formatValue: Int32
        var password: String? = nil
        switch format {
        case .zip(let pwd):
            formatValue = 1
            password = pwd
        case .tar: formatValue = 2
        case .tarGzip: formatValue = 3
        case .tarBzip2: formatValue = 4
        case .tarXz: formatValue = 5
        case .zip7(let pwd):
            formatValue = 6
            password = pwd
        case .bzip2: formatValue = 7
        case .xz: formatValue = 8
        case .gzip: formatValue = 9
        }
        
        // 实现将在C函数中完成
        let result = compressFiles(sourcePath, archivePath, Int32(formatValue), password, cancelFlag)
        
        if result != 0 {
            switch result {
            case ERROR_OPEN_FILE_FAILED:
                throw ArchiveError.openFileFailed
            case ERROR_CREATE_ARCHIVE_FAILED:
                throw ArchiveError.createArchiveFailed
            case ERROR_COMPRESS_FAILED:
                throw ArchiveError.compressFailed
            case ERROR_UNSUPPORTED_FORMAT:
                throw ArchiveError.unsupportedFormat
            case ERROR_OPERATION_CANCELLED:
                throw ArchiveError.operationCancelled
            default:
                throw ArchiveError.unknownError("Unknown error code: \(result)")
            }
        }
    }
    
    /// 异步压缩文件或目录
    /// - Parameters:
    ///   - sourcePath: 源文件或目录路径
    ///   - archivePath: 目标压缩包路径
    ///   - format: 压缩格式
    ///   - password: 压缩密码（如果需要）
    ///   - progress: 进度回调
    ///   - completion: 完成回调
    /// - Returns: 任务ID，可用于取消操作
    @discardableResult
    public func compress(sourcePath: String, to archivePath: String, format: ArchiveFormat, progress: ProgressCallback? = nil, completion: @escaping CompletionCallback) -> UUID {
        let taskId = createTask(outputPath: archivePath, outputType: .compress, createdDestination: true)
        let cancelFlag = cancelPointer(for: taskId)
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else {
                completion(.failure(.unknownError("Self is nil")))
                return
            }
            
            // 模拟进度更新
            var currentProgress: Float = 0.0
            let progressTimer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
            
            progressTimer.setEventHandler { [weak self] in
                guard let self = self, !self.isTaskCancelled(taskId) else {
                    progressTimer.cancel()
                    return
                }
                
                // 增加进度，最大到0.95（留5%给最终处理）
                if currentProgress < 0.95 {
                    currentProgress += 0.05
                    DispatchQueue.main.async {
                        progress?(currentProgress)
                    }
                }
            }
            
            progressTimer.schedule(deadline: .now(), repeating: .milliseconds(200))
            progressTimer.resume()
            
            do {
                // 检查任务是否已取消
                if self.isTaskCancelled(taskId) {
                    progressTimer.cancel()
                    DispatchQueue.main.async {
                        completion(.failure(.operationCancelled))
                    }
                    self.cleanupOutputIfNeeded(taskId)
                    self.removeTask(taskId)
                    return
                }
                
                // 执行压缩操作
                try self.compress(sourcePath: sourcePath, to: archivePath, format: format, cancelFlag: cancelFlag)
                
                // 检查任务是否已取消
                if self.isTaskCancelled(taskId) {
                    progressTimer.cancel()
                    DispatchQueue.main.async {
                        completion(.failure(.operationCancelled))
                    }
                    self.cleanupOutputIfNeeded(taskId)
                    self.removeTask(taskId)
                    return
                }
                
                // 完成进度
                progressTimer.cancel()
                DispatchQueue.main.async {
                    progress?(1.0)
                    completion(.success(()))
                }
            } catch {
                progressTimer.cancel()
                DispatchQueue.main.async {
                    if self.isTaskCancelled(taskId) {
                        completion(.failure(.operationCancelled))
                        self.cleanupOutputIfNeeded(taskId)
                    } else if let archiveError = error as? ArchiveError {
                        if archiveError == .operationCancelled {
                            self.cleanupOutputIfNeeded(taskId)
                        }
                        completion(.failure(archiveError))
                    } else {
                        completion(.failure(.unknownError(error.localizedDescription)))
                    }
                }
            }
            
            self.removeTask(taskId)
        }
        
        return taskId
    }

    /// 取消压缩任务
    /// - Parameter taskId: 任务ID
    public func cancelCompress(taskId: UUID) {
        cancelTask(taskId)
    }
    
    /// 检测压缩包是否需要密码（同步方法）
    /// - Parameter archivePath: 压缩包路径
    /// - Returns: 是否需要密码
    /// - Throws: 检测过程中的错误
    public func isPasswordRequired(archivePath: String) throws -> Bool {
        // 实现将在C函数中完成
        let result = checkArchiveEncryption(archivePath)
        
        switch result {
        case ENCRYPTION_NONE:
            return false
        case ENCRYPTION_PRESENT:
            return true
        case ENCRYPTION_UNSUPPORTED:
            throw ArchiveError.unsupportedFormat
        case ERROR_OPEN_FILE_FAILED:
            throw ArchiveError.openFileFailed
        case ENCRYPTION_UNKNOWN:
            // 未知状态，保守起见返回可能需要密码
            return true
        default:
            throw ArchiveError.unknownError("Unknown error code: \(result)")
        }
    }
    
    /// 异步检测压缩包是否需要密码
    /// - Parameters:
    ///   - archivePath: 压缩包路径
    ///   - completion: 完成回调，返回是否需要密码或错误
    /// - Returns: 任务ID，可用于取消操作
    @discardableResult
    public func isPasswordRequiredAsync(archivePath: String, completion: @escaping (Result<Bool, ArchiveError>) -> Void) -> UUID {
        let taskId = createTask(outputPath: nil, outputType: .none, createdDestination: false)
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else {
                completion(.failure(.unknownError("Self is nil")))
                return
            }
            
            // 检查任务是否已取消
            if self.isTaskCancelled(taskId) {
                DispatchQueue.main.async {
                    completion(.failure(.operationCancelled))
                }
                self.removeTask(taskId)
                return
            }
            
            do {
                let isRequired = try self.isPasswordRequired(archivePath: archivePath)
                
                // 再次检查任务是否已取消
                if self.isTaskCancelled(taskId) {
                    DispatchQueue.main.async {
                        completion(.failure(.operationCancelled))
                    }
                } else {
                    DispatchQueue.main.async {
                        completion(.success(isRequired))
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    if self.isTaskCancelled(taskId) {
                        completion(.failure(.operationCancelled))
                    } else if let archiveError = error as? ArchiveError {
                        completion(.failure(archiveError))
                    } else {
                        completion(.failure(.unknownError(error.localizedDescription)))
                    }
                }
            }
            
            self.removeTask(taskId)
        }
        
        return taskId
    }
    
    /// 取消密码检测任务
    /// - Parameter taskId: 任务ID
    public func cancelPasswordCheck(taskId: UUID) {
        cancelTask(taskId)
    }
    
    /// 检查文件是否支持解压（同步方法）
    /// - Parameter filePath: 文件路径
    /// - Returns: 是否支持解压
    /// - Throws: 检测过程中的错误
    public func isSupportedArchive(filePath: String) throws -> Bool {
        // 实现将在C函数中完成
        let result = checkArchiveFormatSupport(filePath)
        
        if result < 0 {
            throw ArchiveError.unknownError("检查文件格式支持时出错: \(result)")
        }
        
        return result == 1
    }
    
    /// 异步检查文件是否支持解压
    /// - Parameters:
    ///   - filePath: 文件路径
    ///   - completion: 完成回调，返回是否支持解压或错误
    /// - Returns: 任务ID，可用于取消操作
    @discardableResult
    public func isSupportedArchiveAsync(filePath: String, completion: @escaping (Result<Bool, ArchiveError>) -> Void) -> UUID {
        let taskId = createTask(outputPath: nil, outputType: .none, createdDestination: false)
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else {
                completion(.failure(.unknownError("Self is nil")))
                return
            }
            
            // 检查任务是否已取消
            if self.isTaskCancelled(taskId) {
                DispatchQueue.main.async {
                    completion(.failure(.operationCancelled))
                }
                self.removeTask(taskId)
                return
            }
            
            do {
                let isSupported = try self.isSupportedArchive(filePath: filePath)
                
                // 再次检查任务是否已取消
                if self.isTaskCancelled(taskId) {
                    DispatchQueue.main.async {
                        completion(.failure(.operationCancelled))
                    }
                } else {
                    DispatchQueue.main.async {
                        completion(.success(isSupported))
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    if self.isTaskCancelled(taskId) {
                        completion(.failure(.operationCancelled))
                    } else if let archiveError = error as? ArchiveError {
                        completion(.failure(archiveError))
                    } else {
                        completion(.failure(.unknownError(error.localizedDescription)))
                    }
                }
            }
            
            self.removeTask(taskId)
        }
        
        return taskId
    }
    
    /// 取消文件格式支持检查任务
    /// - Parameter taskId: 任务ID
    public func cancelFormatSupportCheck(taskId: UUID) {
        cancelTask(taskId)
    }
}

// MARK: - 错误代码常量

// 错误代码定义
fileprivate let ERROR_CREATE_ARCHIVE_FAILED: Int32 = -1
fileprivate let ERROR_OPEN_FILE_FAILED: Int32 = -2
fileprivate let ERROR_READ_ENTRY_FAILED: Int32 = -3
fileprivate let ERROR_EXTRACT_FAILED: Int32 = -4
fileprivate let ERROR_COMPRESS_FAILED: Int32 = -5
fileprivate let ERROR_PASSWORD_REQUIRED: Int32 = -6
fileprivate let ERROR_WRONG_PASSWORD: Int32 = -7
fileprivate let ERROR_UNSUPPORTED_FORMAT: Int32 = -8
fileprivate let ERROR_OPERATION_CANCELLED: Int32 = -9

// 加密检测结果
fileprivate let ENCRYPTION_NONE: Int32 = 0
fileprivate let ENCRYPTION_PRESENT: Int32 = 1
fileprivate let ENCRYPTION_UNKNOWN: Int32 = -1
fileprivate let ENCRYPTION_UNSUPPORTED: Int32 = -2

// MARK: - C函数声明

/// 解压缩文件的C函数
/// - Parameters:
///   - archivePath: 压缩包路径
///   - destinationPath: 解压目标路径
///   - password: 解压密码（如果需要）
/// - Returns: 0表示成功，其他值表示错误代码
@_silgen_name("extract_archive")
fileprivate func extractArchive(_ archivePath: UnsafePointer<CChar>, _ destinationPath: UnsafePointer<CChar>, _ password: UnsafePointer<CChar>?, _ cancelFlag: UnsafeMutablePointer<Int32>?) -> Int32

/// 压缩文件或目录的C函数
/// - Parameters:
///   - sourcePath: 源文件或目录路径
///   - archivePath: 目标压缩包路径
///   - format: 压缩格式（1=zip, 2=tar, 3=tar.gz, 4=7z）
///   - password: 压缩密码（如果需要）
/// - Returns: 0表示成功，其他值表示错误代码
@_silgen_name("compress_files")
fileprivate func compressFiles(_ sourcePath: UnsafePointer<CChar>, _ archivePath: UnsafePointer<CChar>, _ format: Int32, _ password: UnsafePointer<CChar>?, _ cancelFlag: UnsafeMutablePointer<Int32>?) -> Int32

/// 检测压缩包是否需要密码的C函数
/// - Parameter archivePath: 压缩包路径
/// - Returns: 0表示不需要密码，1表示需要密码，负值表示错误
@_silgen_name("check_archive_encryption")
fileprivate func checkArchiveEncryption(_ archivePath: UnsafePointer<CChar>) -> Int32

/// 检查文件是否支持解压的C函数
/// - Parameter filePath: 文件路径
/// - Returns: 1表示支持解压，0表示不支持解压，负值表示错误
@_silgen_name("check_archive_format_support")
fileprivate func checkArchiveFormatSupport(_ filePath: UnsafePointer<CChar>) -> Int32
