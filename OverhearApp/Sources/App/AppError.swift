import Foundation

/// Centralized error type for the application
/// This provides a consistent error handling strategy across all services
enum AppError: LocalizedError, CustomDebugStringConvertible {
    // MARK: - Audio Errors
    case audioNotFound(String)
    case audioCaptureFailed(String)
    case transcriptionFailed(String)
    case whisperModelNotFound(String)
    
    // MARK: - File I/O Errors
    case storageDirectoryNotFound
    case fileSaveFailure(String)
    case fileReadFailure(String)
    
    // MARK: - Encryption Errors
    case encryptionFailed(String)
    case decryptionFailed(String)
    case keyManagementFailed(String)
    
    // MARK: - Calendar Errors
    case calendarAccessDenied
    case calendarAccessFailed(String)
    
    // MARK: - Permission Errors
    case permissionDenied(String)
    case permissionRequestFailed(String)
    
    // MARK: - Generic Errors
    case invalidInput(String)
    case operationFailed(String)
    case unknown(Error)
    
    // MARK: - LocalizedError Implementation
    
    var errorDescription: String? {
        switch self {
        // Audio
        case .audioNotFound(let path):
            return "Audio tool not found at \(path)"
        case .audioCaptureFailed(let message):
            return "Audio capture failed: \(message)"
        case .transcriptionFailed(let message):
            return "Transcription failed: \(message)"
        case .whisperModelNotFound(let path):
            return "Whisper model not found at \(path)"
            
        // File I/O
        case .storageDirectoryNotFound:
            return "Storage directory could not be accessed or created"
        case .fileSaveFailure(let message):
            return "Failed to save file: \(message)"
        case .fileReadFailure(let message):
            return "Failed to read file: \(message)"
            
        // Encryption
        case .encryptionFailed(let message):
            return "Encryption failed: \(message)"
        case .decryptionFailed(let message):
            return "Decryption failed: \(message)"
        case .keyManagementFailed(let message):
            return "Encryption key management failed: \(message)"
            
        // Calendar
        case .calendarAccessDenied:
            return "Calendar access was denied. Please enable it in System Preferences."
        case .calendarAccessFailed(let message):
            return "Calendar access failed: \(message)"
            
        // Permissions
        case .permissionDenied(let permission):
            return "Permission denied: \(permission)"
        case .permissionRequestFailed(let message):
            return "Permission request failed: \(message)"
            
        // Generic
        case .invalidInput(let message):
            return "Invalid input: \(message)"
        case .operationFailed(let message):
            return "Operation failed: \(message)"
        case .unknown(let error):
            return error.localizedDescription
        }
    }
    
    var recoverySuggestion: String? {
        switch self {
        case .audioNotFound:
            return "Please ensure AudioSpike is installed at the expected location"
        case .whisperModelNotFound:
            return "Please download the Whisper model file"
        case .calendarAccessDenied:
            return "Open System Preferences > Privacy & Security > Calendar and enable access"
        case .storageDirectoryNotFound:
            return "Please check your disk space and file permissions"
        default:
            return "Please try again or contact support if the problem persists"
        }
    }
    
    var debugDescription: String {
        let errorDesc = errorDescription ?? "Unknown error"
        let suggestion = recoverySuggestion ?? ""
        return "\(errorDesc)\n\(suggestion)"
    }
    
    // MARK: - Convenience Initializers
    
    /// Create AppError from any Swift Error
    static func from(_ error: Error) -> AppError {
        if let appError = error as? AppError {
            return appError
        }
        return .unknown(error)
    }
}

// MARK: - Error Conversion Extension

extension AppError {
    /// Convert service-specific error to AppError
    /// Useful for error handling at service boundaries
    static func convertAudioError(_ error: Error) -> AppError {
        if let nsError = error as? NSError {
            return .audioCaptureFailed(nsError.localizedDescription)
        }
        return .audioCaptureFailed(error.localizedDescription)
    }
    
    static func convertFileError(_ error: Error) -> AppError {
        let nsError = error as NSError
        switch nsError.code {
        case NSFileNoSuchFileError:
            return .fileReadFailure("File not found")
        case NSFileWriteOutOfSpaceError:
            return .fileSaveFailure("Out of disk space")
        default:
            return .fileReadFailure(nsError.localizedDescription)
        }
    }
    
    static func convertCalendarError(_ error: Error) -> AppError {
        if let nsError = error as? NSError {
            return .calendarAccessFailed(nsError.localizedDescription)
        }
        return .calendarAccessFailed(error.localizedDescription)
    }
}
