#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "../libarchive_src/libarchive/archive.h"
#include "../libarchive_src/libarchive/archive_entry.h"
#include <fcntl.h>
#include <limits.h>
#include <sys/stat.h>
#include <dirent.h>
#include <unistd.h>

#include "include/libarchive_wrapper.h"

// 函数声明
static int copy_data(struct archive *ar, struct archive *aw, volatile int *cancel_flag);
static int add_directory_to_archive(struct archive *a, const char *dir_path, const char *parent_path, volatile int *cancel_flag);

// 复制数据从一个归档到另一个归档
static int copy_data(struct archive *ar, struct archive *aw, volatile int *cancel_flag) {
    int r;
    const void *buff;
    size_t size;
    la_int64_t offset;
    
    for (;;) {
        if (cancel_flag && *cancel_flag) {
            fprintf(stderr, "[cancel_flag] copy_data detected cancel (value=%d)\n", *cancel_flag);
            return ERROR_OPERATION_CANCELLED;
        }
        r = archive_read_data_block(ar, &buff, &size, &offset);
        if (r == ARCHIVE_EOF)
            return ARCHIVE_OK;
        if (r < ARCHIVE_OK)
            return r;
        r = archive_write_data_block(aw, buff, size, offset);
        if (r < ARCHIVE_OK) {
            fprintf(stderr, "%s\n", archive_error_string(aw));
            return r;
        }
    }
}

// 递归添加目录到归档
static int add_directory_to_archive(struct archive *a, const char *dir_path, const char *parent_path, volatile int *cancel_flag) {
    DIR *dir;
    struct dirent *entry;
    struct stat st;
    char full_path[512];
    char archive_path[512];
    int r = ARCHIVE_OK;
    
    dir = opendir(dir_path);
    if (dir == NULL) {
        fprintf(stderr, "无法打开目录: %s\n", dir_path);
        return ARCHIVE_FATAL;
    }
    
    while ((entry = readdir(dir)) != NULL) {
        if (cancel_flag && *cancel_flag) {
            fprintf(stderr, "[cancel_flag] add_directory_to_archive detected cancel (value=%d)\n", *cancel_flag);
            closedir(dir);
            return ERROR_OPERATION_CANCELLED;
        }
        // 跳过 . 和 ..
        if (strcmp(entry->d_name, ".") == 0 || strcmp(entry->d_name, "..") == 0)
            continue;
        
        // 构建完整路径
        snprintf(full_path, sizeof(full_path), "%s/%s", dir_path, entry->d_name);
        
        // 构建归档内路径
        if (parent_path && strlen(parent_path) > 0) {
            snprintf(archive_path, sizeof(archive_path), "%s/%s", parent_path, entry->d_name);
        } else {
            snprintf(archive_path, sizeof(archive_path), "%s", entry->d_name);
        }
        
        if (stat(full_path, &st) != 0) {
            fprintf(stderr, "无法获取文件状态: %s\n", full_path);
            continue;
        }
        
        if (S_ISDIR(st.st_mode)) {
            // 处理目录
            struct archive_entry *entry = archive_entry_new();
            archive_entry_set_pathname(entry, archive_path);
            archive_entry_set_mode(entry, st.st_mode);
            archive_entry_set_size(entry, 0);
            archive_entry_set_mtime(entry, st.st_mtime, 0);
            archive_entry_set_filetype(entry, AE_IFDIR);
            
            r = archive_write_header(a, entry);
            archive_entry_free(entry);
            
            if (r < ARCHIVE_OK) {
                fprintf(stderr, "%s\n", archive_error_string(a));
                closedir(dir);
                return r;
            }
            
            // 递归处理子目录
            r = add_directory_to_archive(a, full_path, archive_path, cancel_flag);
            if (r < ARCHIVE_OK) {
                closedir(dir);
                return r;
            }
        } else if (S_ISREG(st.st_mode)) {
            // 处理常规文件
            struct archive_entry *entry = archive_entry_new();
            archive_entry_set_pathname(entry, archive_path);
            archive_entry_set_size(entry, st.st_size);
            archive_entry_set_mode(entry, st.st_mode);
            archive_entry_set_mtime(entry, st.st_mtime, 0);
            archive_entry_set_filetype(entry, AE_IFREG);
            
            r = archive_write_header(a, entry);
            archive_entry_free(entry);
            
            if (r < ARCHIVE_OK) {
                fprintf(stderr, "%s\n", archive_error_string(a));
                closedir(dir);
                return r;
            }
            
            // 写入文件内容
            FILE *file = fopen(full_path, "rb");
            if (file) {
                char buffer[8192];
                size_t bytes_read;
                while ((bytes_read = fread(buffer, 1, sizeof(buffer), file)) > 0) {
                    archive_write_data(a, buffer, bytes_read);
                }
                fclose(file);
            } else {
                fprintf(stderr, "无法打开文件: %s\n", full_path);
                closedir(dir);
                return ARCHIVE_FATAL;
            }
        }
    }
    
    closedir(dir);
    return ARCHIVE_OK;
}

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
#define ERROR_OPERATION_CANCELLED -9

// 加密检测结果
#define ENCRYPTION_NONE 0
#define ENCRYPTION_PRESENT 1
#define ENCRYPTION_UNKNOWN -1
#define ENCRYPTION_UNSUPPORTED -2

/**
 * 解压缩归档文件
 * @param archive_path 归档文件路径
 * @param destination_path 目标路径
 * @param password 密码（可为NULL）
 * @param cancel_flag 取消标记指针（可为NULL，为1时中断操作）
 * @return 成功返回SUCCESS，失败返回错误代码
 */
int extract_archive(const char *archive_path, const char *destination_path, const char *password, volatile int *cancel_flag) {
    struct archive *a = NULL;
    struct archive *ext = NULL;
    struct archive_entry *entry;
    int flags;
    int r;
    int result = SUCCESS;
    char current_dir[PATH_MAX];
    int changed_dir = 0;
    
    if (cancel_flag && *cancel_flag) {
        fprintf(stderr, "[cancel_flag] extract_archive early cancel before start (value=%d)\n", *cancel_flag);
        return ERROR_OPERATION_CANCELLED;
    }
    
    // 选择要支持的格式和过滤器
    flags = ARCHIVE_EXTRACT_TIME;
    flags |= ARCHIVE_EXTRACT_PERM;
    flags |= ARCHIVE_EXTRACT_ACL;
    flags |= ARCHIVE_EXTRACT_FFLAGS;
    
    // 初始化读取归档
    a = archive_read_new();
    archive_read_support_format_all(a);
    archive_read_support_filter_all(a);
    
    // 如果提供了密码，设置密码
    if (password != NULL) {
        r = archive_read_add_passphrase(a, password);
        if (r != ARCHIVE_OK) {
            fprintf(stderr, "设置密码失败: %s\n", archive_error_string(a));
            result = ERROR_WRONG_PASSWORD;
            goto cleanup;
        }
    }
    
    // 初始化写入磁盘
    ext = archive_write_disk_new();
    archive_write_disk_set_options(ext, flags);
    archive_write_disk_set_standard_lookup(ext);
    
    // 打开归档文件
    if ((r = archive_read_open_filename(a, archive_path, 10240)) != ARCHIVE_OK) {
        fprintf(stderr, "无法打开归档文件: %s\n", archive_error_string(a));
        result = ERROR_OPEN_FILE_FAILED;
        goto cleanup;
    }
    
    // 创建目标目录（如果不存在）
    struct stat st = {0};
    if (stat(destination_path, &st) == -1) {
        mkdir(destination_path, 0755);
    }
    
    // 切换到目标目录
    if (getcwd(current_dir, sizeof(current_dir)) == NULL) {
        fprintf(stderr, "获取当前目录失败\n");
        result = ERROR_EXTRACT_FAILED;
        goto cleanup;
    }
    
    if (chdir(destination_path) != 0) {
        fprintf(stderr, "无法切换到目标目录: %s\n", destination_path);
        result = ERROR_EXTRACT_FAILED;
        goto cleanup;
    }
    changed_dir = 1;
    
    // 解压缩归档
    for (;;) {
        if (cancel_flag && *cancel_flag) {
            fprintf(stderr, "[cancel_flag] extract_archive loop detected cancel (value=%d)\n", *cancel_flag);
            result = ERROR_OPERATION_CANCELLED;
            goto cleanup;
        }
        r = archive_read_next_header(a, &entry);
        if (r == ARCHIVE_EOF)
            break;
        
        if (r == ARCHIVE_RETRY) {
            fprintf(stderr, "重试: %s\n", archive_error_string(a));
            continue;
        }
        
        // 检查条目是否加密
        if (archive_entry_is_encrypted(entry)) {
            if (password == NULL) {
                fprintf(stderr, "条目已加密，需要密码\n");
                result = ERROR_PASSWORD_REQUIRED;
                goto cleanup;
            }
            // 如果提供了密码但仍然有问题，可能是密码错误
            if (r < ARCHIVE_OK) {
                fprintf(stderr, "条目已加密，密码可能不正确\n");
                result = ERROR_WRONG_PASSWORD;
                goto cleanup;
            }
        }
        
        if (r == ARCHIVE_WARN) {
            fprintf(stderr, "警告: %s\n", archive_error_string(a));
        } else if (r < ARCHIVE_OK) {
            fprintf(stderr, "错误: %s\n", archive_error_string(a));
            result = ERROR_READ_ENTRY_FAILED;
            goto cleanup;
        }
        
        r = archive_write_header(ext, entry);
        if (r < ARCHIVE_OK) {
            fprintf(stderr, "%s\n", archive_error_string(ext));
        } else if (archive_entry_size(entry) > 0) {
            r = copy_data(a, ext, cancel_flag);
            if (r == ERROR_OPERATION_CANCELLED) {
                result = ERROR_OPERATION_CANCELLED;
                goto cleanup;
            }
            if (r < ARCHIVE_OK) {
                fprintf(stderr, "%s\n", archive_error_string(ext));
                result = ERROR_EXTRACT_FAILED;
                goto cleanup;
            }
        }
    }
    
cleanup:
    if (changed_dir) {
    chdir(current_dir);
    }
    
    if (a != NULL) {
    archive_read_close(a);
    archive_read_free(a);
    }
    
    if (ext != NULL) {
    archive_write_close(ext);
    archive_write_free(ext);
    }
    
    return result;
}

/**
 * 压缩文件或目录到归档
 * @param source_path 源文件或目录路径
 * @param archive_path 归档文件路径
 * @param format 格式（1=zip, 2=tar, 3=tar.gz, 4=7z）
 * @param password 密码（可为NULL）
 * @return 成功返回SUCCESS，失败返回错误代码
 */
int compress_files(const char *source_path, const char *archive_path, int format, const char *password, volatile int *cancel_flag) {
    struct archive *a = NULL;
    struct stat st;
    int r;
    int result = SUCCESS;
    
    if (cancel_flag && *cancel_flag) {
        fprintf(stderr, "[cancel_flag] compress_files early cancel before start (value=%d)\n", *cancel_flag);
        return ERROR_OPERATION_CANCELLED;
    }
    
    // 检查源路径是否存在
    if (stat(source_path, &st) != 0) {
        fprintf(stderr, "源路径不存在: %s\n", source_path);
        result = ERROR_OPEN_FILE_FAILED;
        goto cleanup;
    }
    
    // 创建新的归档写入对象
    a = archive_write_new();
    
    // 根据格式设置相应的过滤器和格式
    switch (format) {
        case 1: // ZIP
            archive_write_set_format_zip(a);
            break;
        case 2: // TAR
            archive_write_set_format_pax_restricted(a);
            break;
        case 3: // TAR.GZ
            archive_write_set_format_pax_restricted(a);
            archive_write_add_filter_gzip(a);
            break;
        case 4: // TAR.BZ2
            archive_write_set_format_pax_restricted(a);
            archive_write_add_filter_bzip2(a);
            break;
        case 5: // TAR.XZ
            archive_write_set_format_pax_restricted(a);
            archive_write_add_filter_xz(a);
            break;
        case 6: // 7Z
            archive_write_set_format_7zip(a);
            break;
        case 7: // BZIP2
            archive_write_set_format_raw(a);
            archive_write_add_filter_bzip2(a);
            break;
        case 8: // XZ
            archive_write_set_format_raw(a);
            archive_write_add_filter_xz(a);
            break;
        case 9: // GZIP
            archive_write_set_format_raw(a);
            archive_write_add_filter_gzip(a);
            break;
        default:
            fprintf(stderr, "不支持的格式: %d\n", format);
            result = ERROR_UNSUPPORTED_FORMAT;
            goto cleanup;
    }
    
    // 如果提供了密码，设置密码（仅对支持加密的格式有效）
    if (password != NULL) {
        if (format == 1 || format == 6) { // ZIP 或 7Z
            r = archive_write_set_passphrase(a, password);
            if (r != ARCHIVE_OK) {
                fprintf(stderr, "设置密码失败: %s\n", archive_error_string(a));
                result = ERROR_COMPRESS_FAILED;
                goto cleanup;
            }
            
            // 根据格式启用相应的加密
            if (format == 1) { // ZIP
                r = archive_write_set_options(a, "zip:encryption=traditional");
                if (r != ARCHIVE_OK) {
                    fprintf(stderr, "启用ZIP加密失败: %s\n", archive_error_string(a));
                    result = ERROR_COMPRESS_FAILED;
                    goto cleanup;
                }
            }
            // 7Z格式默认支持加密，不需要额外设置
        } else {
            fprintf(stderr, "警告: 所选格式不支持加密，密码将被忽略\n");
        }
    }
    
    // 打开归档文件进行写入
    r = archive_write_open_filename(a, archive_path);
    if (r != ARCHIVE_OK) {
        fprintf(stderr, "无法创建归档文件: %s\n", archive_error_string(a));
        result = ERROR_CREATE_ARCHIVE_FAILED;
        goto cleanup;
    }
    
    // 处理源路径（文件或目录）
    if (S_ISDIR(st.st_mode)) {
        // 处理目录
        r = add_directory_to_archive(a, source_path, NULL, cancel_flag);
        if (r < ARCHIVE_OK) {
            fprintf(stderr, "添加目录到归档失败: %s\n", archive_error_string(a));
            result = (r == ERROR_OPERATION_CANCELLED) ? ERROR_OPERATION_CANCELLED : ERROR_COMPRESS_FAILED;
            goto cleanup;
        }
    } else if (S_ISREG(st.st_mode)) {
        // 处理单个文件
        struct archive_entry *entry = archive_entry_new();
        
        // 获取文件名（不包含路径）
        const char *filename = strrchr(source_path, '/');
        if (filename == NULL) {
            filename = source_path;
        } else {
            filename++; // 跳过 '/'
        }
        
        archive_entry_set_pathname(entry, filename);
        archive_entry_set_size(entry, st.st_size);
        archive_entry_set_mode(entry, st.st_mode);
        archive_entry_set_mtime(entry, st.st_mtime, 0);
        archive_entry_set_filetype(entry, AE_IFREG);
        
        r = archive_write_header(a, entry);
        archive_entry_free(entry);
        
        if (r < ARCHIVE_OK) {
            fprintf(stderr, "%s\n", archive_error_string(a));
            result = ERROR_COMPRESS_FAILED;
            goto cleanup;
        }
        
        // 写入文件内容
        FILE *file = fopen(source_path, "rb");
        if (file) {
            char buffer[8192];
            size_t bytes_read;
            while ((bytes_read = fread(buffer, 1, sizeof(buffer), file)) > 0) {
                if (cancel_flag && *cancel_flag) {
                    fprintf(stderr, "[cancel_flag] compress_files write loop detected cancel (value=%d)\n", *cancel_flag);
                    fclose(file);
                    result = ERROR_OPERATION_CANCELLED;
                    goto cleanup;
                }
                archive_write_data(a, buffer, bytes_read);
            }
            fclose(file);
        } else {
            fprintf(stderr, "无法打开文件: %s\n", source_path);
            result = ERROR_OPEN_FILE_FAILED;
            goto cleanup;
        }
    } else {
        fprintf(stderr, "不支持的文件类型: %s\n", source_path);
        result = ERROR_UNSUPPORTED_FORMAT;
        goto cleanup;
    }
    
cleanup:
    if (a != NULL) {
        archive_write_close(a);
        archive_write_free(a);
    }
    
    return result;
}

/**
 * 检查归档文件是否需要密码
 * @param archive_path 归档文件路径
 * @return ENCRYPTION_NONE=不需要密码, ENCRYPTION_PRESENT=需要密码, 
 *         ENCRYPTION_UNKNOWN=未知, ENCRYPTION_UNSUPPORTED=不支持的格式
 */
int check_archive_encryption(const char *archive_path) {
    struct archive *a;
    struct archive_entry *entry;
    int r;
    int has_encrypted_entries = 0;
    
    // 初始化读取归档
    a = archive_read_new();
    archive_read_support_format_all(a);
    archive_read_support_filter_all(a);
    
    // 打开归档文件
    if ((r = archive_read_open_filename(a, archive_path, 10240)) != ARCHIVE_OK) {
        fprintf(stderr, "无法打开归档文件: %s\n", archive_error_string(a));
        archive_read_free(a);
        return ERROR_OPEN_FILE_FAILED;
    }
    
    // 逐个检查条目是否加密
    while (archive_read_next_header(a, &entry) == ARCHIVE_OK) {
        if (archive_entry_is_encrypted(entry)) {
            has_encrypted_entries = 1;
            break;
        }
        archive_read_data_skip(a);
    }
    
    // 关闭并释放资源
    archive_read_close(a);
    archive_read_free(a);
    
    if (has_encrypted_entries) {
        return ENCRYPTION_PRESENT; // 需要密码
    } else {
        return ENCRYPTION_NONE; // 不需要密码
    }
}

/**
 * 检查文件是否支持解压
 * @param file_path 文件路径
 * @return 1=支持解压, 0=不支持解压, 负值表示错误
 */
int check_archive_format_support(const char *file_path) {
    struct archive *a;
    int r;
    int supported = 0;
    
    // 初始化读取归档
    a = archive_read_new();
    archive_read_support_format_all(a);
    archive_read_support_filter_all(a);
    
    // 打开文件
    r = archive_read_open_filename(a, file_path, 10240);
    if (r == ARCHIVE_OK) {
        // 文件可以被libarchive打开，表示支持解压
        supported = 1;
        archive_read_close(a);
    } else {
        // 文件不能被libarchive打开，表示不支持解压
        supported = 0;
    }
    
    // 释放资源
    archive_read_free(a);
    
    return supported;
}