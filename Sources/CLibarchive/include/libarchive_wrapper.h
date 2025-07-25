#ifndef libarchive_wrapper_h
#define libarchive_wrapper_h

#ifdef __cplusplus
extern "C" {
#endif

/**
 * 解压缩文件
 * @param archive_path 压缩包路径
 * @param destination_path 解压目标路径
 * @param password 解压密码（如果需要）
 * @return 0表示成功，其他值表示错误代码
 */
int extract_archive(const char *archive_path, const char *destination_path, const char *password);

/**
 * 压缩文件或目录
 * @param source_path 源文件或目录路径
 * @param archive_path 目标压缩包路径
 * @param format 压缩格式（1=zip, 2=tar, 3=tar.gz, 4=tar.bz2, 5=tar.xz, 6=7z, 7=bzip2, 8=xz, 9=gzip）
 * @param password 压缩密码（如果需要，仅ZIP和7Z格式支持）
 * @return 0表示成功，其他值表示错误代码
 */
int compress_files(const char *source_path, const char *archive_path, int format, const char *password);

/**
 * 检测压缩包是否需要密码
 * @param archive_path 压缩包路径
 * @return 0表示不需要密码，1表示需要密码，负值表示错误
 */
int check_archive_encryption(const char *archive_path);

/**
 * 检查文件是否支持解压
 * @param file_path 文件路径
 * @return 1表示支持解压，0表示不支持解压，负值表示错误
 */
int check_archive_format_support(const char *file_path);

// 错误代码定义
#define SUCCESS 0
#define ERROR_CREATE_ARCHIVE_FAILED -1
#define ERROR_OPEN_FILE_FAILED -2
#define ERROR_READ_ENTRY_FAILED -3
#define ERROR_EXTRACT_FAILED -4
#define ERROR_COMPRESS_FAILED -5
#define ERROR_PASSWORD_REQUIRED -6
#define ERROR_WRONG_PASSWORD -7
#define ERROR_UNSUPPORTED_FORMAT -8

// 加密检测结果
#define ENCRYPTION_NONE 0
#define ENCRYPTION_PRESENT 1
#define ENCRYPTION_UNKNOWN -1
#define ENCRYPTION_UNSUPPORTED -2

#ifdef __cplusplus
}
#endif

#endif /* libarchive_wrapper_h */