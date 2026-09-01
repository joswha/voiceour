#include "ggml.h"

#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

#include <algorithm>
#include <array>
#include <cerrno>
#include <charconv>
#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <cstdio>
#include <cstring>
#include <filesystem>
#include <exception>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <limits>
#include <map>
#include <memory>
#include <set>
#include <sstream>
#include <stdexcept>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

namespace {

constexpr uint32_t kModelMagic = 0x67676d6c;
constexpr size_t kHparamCount = 15;
constexpr size_t kAudioLayerHparamIndex = 4;
constexpr size_t kPredictionLayerHparamIndex = 12;
constexpr int32_t kMaximumAudioLayers = 24;
constexpr int32_t kMaximumPredictionLayers = 2;
constexpr size_t kFtypeOffset = sizeof(uint32_t) + 6 * sizeof(int32_t);
constexpr size_t kCopyChunkBytes = 1024 * 1024;
constexpr int32_t kMaximumNameBytes = GGML_MAX_NAME - 1;
constexpr size_t kMaximumTensorRecords = 721;
constexpr size_t kMaximumReportPathBytes = 4096;
constexpr size_t kMaximumDecimalBytes = 20;
constexpr std::string_view kPlanMagic = "# voiceour-parakeet-mixed-plan-v2";
constexpr std::string_view kReportMagic = "# voiceour-parakeet-mixed-report-v2";
constexpr std::string_view kReportColumns =
    "index\tname\tn_dims\tshape\tinput_type\tquant_source_type\t"
    "target_type\tinput_payload_bytes\tquant_source_payload_bytes\t"
    "target_payload_bytes\n";
constexpr size_t kMaximumReportRecordBytes =
    3 + 1 + static_cast<size_t>(kMaximumNameBytes) + 1 + 1 + 1 +
    (4 * 10 + 3) + 1 + 4 + 1 + 4 + 1 + 4 + 1 +
    kMaximumDecimalBytes + 1 + kMaximumDecimalBytes + 1 +
    kMaximumDecimalBytes + 1;
constexpr size_t kMaximumReportHeaderBytes =
    kReportMagic.size() + 1 +
    std::string_view("# input_path=").size() + kMaximumReportPathBytes + 1 +
    std::string_view("# input_size_bytes=").size() +
        kMaximumDecimalBytes + 1 +
    std::string_view("# input_sha256=").size() + 64 + 1 +
    std::string_view("# quant_source_path=").size() +
        kMaximumReportPathBytes + 1 +
    std::string_view("# quant_source_size_bytes=").size() +
        kMaximumDecimalBytes + 1 +
    std::string_view("# quant_source_sha256=").size() + 64 + 1 +
    std::string_view("# nominal_type=").size() + 4 + 1 +
    std::string_view("# output_path=").size() + kMaximumReportPathBytes + 1 +
    std::string_view("# output_size_bytes=").size() +
        kMaximumDecimalBytes + 1 +
    std::string_view("# output_sha256=").size() + 64 + 1 +
    kReportColumns.size();
constexpr size_t kMaximumReportBytes =
    kMaximumReportHeaderBytes +
    kMaximumTensorRecords * kMaximumReportRecordBytes;

static_assert(GGML_MAX_NAME > 1);
static_assert(sizeof(size_t) <= sizeof(uint64_t));
static_assert(kMaximumReportBytes == 151335);
class ConversionError final : public std::runtime_error {
public:
    using std::runtime_error::runtime_error;
};

std::string systemError(const std::string & operation, const std::string & path) {
    return operation + " " + path + ": " + std::strerror(errno);
}

uint32_t rotateRight(uint32_t value, uint32_t amount) {
    return (value >> amount) | (value << (32 - amount));
}

class Sha256 final {
public:
    Sha256()
        : state_({
              0x6a09e667,
              0xbb67ae85,
              0x3c6ef372,
              0xa54ff53a,
              0x510e527f,
              0x9b05688c,
              0x1f83d9ab,
              0x5be0cd19,
          }) {}

    void update(const void * rawData, size_t size) {
        if (finalized_) {
            throw ConversionError("internal SHA-256 update after finalization");
        }
        const auto * data = static_cast<const uint8_t *>(rawData);
        totalBytes_ += size;
        while (size > 0) {
            const size_t available = block_.size() - blockBytes_;
            const size_t count = size < available ? size : available;
            std::memcpy(block_.data() + blockBytes_, data, count);
            blockBytes_ += count;
            data += count;
            size -= count;
            if (blockBytes_ == block_.size()) {
                transform(block_.data());
                blockBytes_ = 0;
            }
        }
    }

    std::array<uint8_t, 32> finalize() {
        if (finalized_) {
            throw ConversionError("internal SHA-256 finalized twice");
        }
        finalized_ = true;
        const uint64_t bitCount = totalBytes_ * 8;
        block_[blockBytes_++] = 0x80;
        if (blockBytes_ > 56) {
            std::fill(block_.begin() + static_cast<ptrdiff_t>(blockBytes_), block_.end(), 0);
            transform(block_.data());
            blockBytes_ = 0;
        }
        std::fill(
            block_.begin() + static_cast<ptrdiff_t>(blockBytes_),
            block_.begin() + 56,
            0
        );
        for (size_t index = 0; index < sizeof(bitCount); ++index) {
            block_[63 - index] = static_cast<uint8_t>(bitCount >> (index * 8));
        }
        transform(block_.data());

        std::array<uint8_t, 32> digest{};
        for (size_t index = 0; index < state_.size(); ++index) {
            digest[index * 4] = static_cast<uint8_t>(state_[index] >> 24);
            digest[index * 4 + 1] = static_cast<uint8_t>(state_[index] >> 16);
            digest[index * 4 + 2] = static_cast<uint8_t>(state_[index] >> 8);
            digest[index * 4 + 3] = static_cast<uint8_t>(state_[index]);
        }
        return digest;
    }

private:
    void transform(const uint8_t * block) {
        static constexpr std::array<uint32_t, 64> constants = {
            0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5,
            0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
            0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
            0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
            0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
            0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
            0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
            0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
            0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
            0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
            0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
            0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
            0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5,
            0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
            0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
            0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
        };

        std::array<uint32_t, 64> words{};
        for (size_t index = 0; index < 16; ++index) {
            const size_t offset = index * 4;
            words[index] =
                (static_cast<uint32_t>(block[offset]) << 24) |
                (static_cast<uint32_t>(block[offset + 1]) << 16) |
                (static_cast<uint32_t>(block[offset + 2]) << 8) |
                static_cast<uint32_t>(block[offset + 3]);
        }
        for (size_t index = 16; index < words.size(); ++index) {
            const uint32_t s0 =
                rotateRight(words[index - 15], 7) ^
                rotateRight(words[index - 15], 18) ^
                (words[index - 15] >> 3);
            const uint32_t s1 =
                rotateRight(words[index - 2], 17) ^
                rotateRight(words[index - 2], 19) ^
                (words[index - 2] >> 10);
            words[index] = words[index - 16] + s0 + words[index - 7] + s1;
        }

        uint32_t a = state_[0];
        uint32_t b = state_[1];
        uint32_t c = state_[2];
        uint32_t d = state_[3];
        uint32_t e = state_[4];
        uint32_t f = state_[5];
        uint32_t g = state_[6];
        uint32_t h = state_[7];
        for (size_t index = 0; index < words.size(); ++index) {
            const uint32_t sum1 =
                rotateRight(e, 6) ^ rotateRight(e, 11) ^ rotateRight(e, 25);
            const uint32_t choice = (e & f) ^ (~e & g);
            const uint32_t temporary1 =
                h + sum1 + choice + constants[index] + words[index];
            const uint32_t sum0 =
                rotateRight(a, 2) ^ rotateRight(a, 13) ^ rotateRight(a, 22);
            const uint32_t majority = (a & b) ^ (a & c) ^ (b & c);
            const uint32_t temporary2 = sum0 + majority;
            h = g;
            g = f;
            f = e;
            e = d + temporary1;
            d = c;
            c = b;
            b = a;
            a = temporary1 + temporary2;
        }
        state_[0] += a;
        state_[1] += b;
        state_[2] += c;
        state_[3] += d;
        state_[4] += e;
        state_[5] += f;
        state_[6] += g;
        state_[7] += h;
    }

    std::array<uint32_t, 8> state_;
    std::array<uint8_t, 64> block_{};
    size_t blockBytes_ = 0;
    uint64_t totalBytes_ = 0;
    bool finalized_ = false;
};

std::string hexadecimal(const std::array<uint8_t, 32> & digest) {
    std::ostringstream output;
    output << std::hex << std::setfill('0');
    for (uint8_t byte : digest) {
        output << std::setw(2) << static_cast<unsigned int>(byte);
    }
    return output.str();
}

struct OpenFileIdentity {
    dev_t device = 0;
    ino_t inode = 0;
    off_t size = 0;
    timespec modificationTime{};
};

timespec modificationTime(const struct stat & status) {
#if defined(__APPLE__)
    return status.st_mtimespec;
#else
    return status.st_mtim;
#endif
}

bool sameIdentity(
    const OpenFileIdentity & expected,
    const struct stat & actual
) {
    const timespec actualModificationTime = modificationTime(actual);
    return
        expected.device == actual.st_dev &&
        expected.inode == actual.st_ino &&
        expected.size == actual.st_size &&
        expected.modificationTime.tv_sec == actualModificationTime.tv_sec &&
        expected.modificationTime.tv_nsec == actualModificationTime.tv_nsec;
}

class OwnedDescriptor final {
public:
    explicit OwnedDescriptor(int descriptor) : descriptor_(descriptor) {}

    ~OwnedDescriptor() {
        if (descriptor_ >= 0) {
            close(descriptor_);
        }
    }

    OwnedDescriptor(const OwnedDescriptor &) = delete;
    OwnedDescriptor & operator=(const OwnedDescriptor &) = delete;

    int get() const { return descriptor_; }

    void closeChecked(const std::string & operation, const std::string & path) {
        const int descriptor = descriptor_;
        descriptor_ = -1;
        if (close(descriptor) != 0) {
            throw ConversionError(systemError(operation, path));
        }
    }

private:
    int descriptor_;
};

class InputFile final {
public:
    explicit InputFile(const std::string & path)
        : path_(path), file_(std::fopen(path.c_str(), "rb")) {
        if (!file_) {
            throw ConversionError(systemError("cannot open", path));
        }
        struct stat status {};
        if (fstat(fileno(file_), &status) != 0) {
            const int savedError = errno;
            std::fclose(file_);
            file_ = nullptr;
            errno = savedError;
            throw ConversionError(systemError("cannot inspect open file", path));
        }
        if (!S_ISREG(status.st_mode) || status.st_size < 0) {
            std::fclose(file_);
            file_ = nullptr;
            throw ConversionError("input is not a regular file: " + path);
        }
        identity_ = {
            status.st_dev,
            status.st_ino,
            status.st_size,
            modificationTime(status),
        };
        verifyUnchanged();
    }

    ~InputFile() {
        if (file_) {
            std::fclose(file_);
        }
    }

    InputFile(const InputFile &) = delete;
    InputFile & operator=(const InputFile &) = delete;

    FILE * get() const { return file_; }
    const std::string & path() const { return path_; }
    int64_t size() const { return static_cast<int64_t>(identity_.size); }

    bool isSameFileAs(const InputFile & other) const {
        return
            identity_.device == other.identity_.device &&
            identity_.inode == other.identity_.inode;
    }

    int64_t tell() const {
        const off_t position = ftello(file_);
        if (position < 0) {
            throw ConversionError(systemError("cannot tell", path_));
        }
        return static_cast<int64_t>(position);
    }

    void seek(int64_t offset) const {
        std::clearerr(file_);
        if (offset < 0 || fseeko(file_, static_cast<off_t>(offset), SEEK_SET) != 0) {
            throw ConversionError(systemError("cannot seek", path_));
        }
    }

    void readExact(void * destination, size_t size, const std::string & description) const {
        if (size == 0) {
            return;
        }
        const size_t count = std::fread(destination, 1, size, file_);
        if (count != size) {
            if (std::ferror(file_)) {
                throw ConversionError(systemError("cannot read", path_));
            }
            throw ConversionError("truncated " + description + " in " + path_);
        }
    }

    std::string hashContents() const {
        seek(0);
        Sha256 hash;
        std::vector<uint8_t> buffer(kCopyChunkBytes);
        uint64_t remaining = static_cast<uint64_t>(identity_.size);
        while (remaining > 0) {
            const size_t count = static_cast<size_t>(
                std::min<uint64_t>(remaining, buffer.size())
            );
            readExact(buffer.data(), count, "source bytes while hashing");
            hash.update(buffer.data(), count);
            remaining -= count;
        }
        verifyUnchanged();
        seek(0);
        return hexadecimal(hash.finalize());
    }

    void verifyUnchanged() const {
        struct stat descriptorStatus {};
        if (fstat(fileno(file_), &descriptorStatus) != 0) {
            throw ConversionError(systemError("cannot re-inspect open file", path_));
        }
        struct stat pathStatus {};
        if (stat(path_.c_str(), &pathStatus) != 0) {
            throw ConversionError(systemError("cannot re-inspect source path", path_));
        }
        if (!sameIdentity(identity_, descriptorStatus) ||
                !sameIdentity(identity_, pathStatus)) {
            throw ConversionError("source changed while conversion was in progress: " + path_);
        }
    }

private:
    std::string path_;
    FILE * file_ = nullptr;
    OpenFileIdentity identity_{};
};

bool existingReportMatchesIfPresent(
    const std::string & path,
    const std::string & expected
) {
    if (expected.size() > kMaximumReportBytes) {
        throw ConversionError("internal conversion report exceeds its size bound");
    }

    int flags = O_RDONLY | O_NONBLOCK;
#if defined(O_CLOEXEC)
    flags |= O_CLOEXEC;
#endif
#if defined(O_NOFOLLOW)
    flags |= O_NOFOLLOW;
#endif
    const int rawDescriptor = open(path.c_str(), flags);
    if (rawDescriptor < 0) {
        if (errno == ENOENT) {
            return false;
        }
#if defined(ELOOP)
        if (errno == ELOOP) {
            throw ConversionError(
                "existing report is not a regular file: " + path
            );
        }
#endif
        throw ConversionError(systemError("cannot open existing report", path));
    }
    OwnedDescriptor descriptor(rawDescriptor);

    struct stat initialStatus {};
    if (fstat(descriptor.get(), &initialStatus) != 0) {
        throw ConversionError(
            systemError("cannot inspect existing report", path)
        );
    }
    if (!S_ISREG(initialStatus.st_mode) || initialStatus.st_size < 0) {
        throw ConversionError(
            "existing report is not a regular file: " + path
        );
    }
    const uint64_t initialSize =
        static_cast<uint64_t>(initialStatus.st_size);
    if (initialSize > kMaximumReportBytes ||
            initialSize != expected.size()) {
        throw ConversionError(
            "existing report size does not match expected report: " + path
        );
    }
    const OpenFileIdentity identity = {
        initialStatus.st_dev,
        initialStatus.st_ino,
        initialStatus.st_size,
        modificationTime(initialStatus),
    };

    std::string actual(expected.size(), '\0');
    size_t offset = 0;
    while (offset < actual.size()) {
        const ssize_t count = read(
            descriptor.get(),
            actual.data() + offset,
            actual.size() - offset
        );
        if (count < 0) {
            if (errno == EINTR) {
                continue;
            }
            throw ConversionError(
                systemError("cannot read existing report", path)
            );
        }
        if (count == 0) {
            throw ConversionError(
                "existing report was truncated while being read: " + path
            );
        }
        offset += static_cast<size_t>(count);
    }

    uint8_t extraByte = 0;
    ssize_t extraCount = 0;
    do {
        extraCount = read(descriptor.get(), &extraByte, 1);
    } while (extraCount < 0 && errno == EINTR);
    if (extraCount < 0) {
        throw ConversionError(
            systemError("cannot finish reading existing report", path)
        );
    }
    if (extraCount != 0) {
        throw ConversionError(
            "existing report grew while being read: " + path
        );
    }

    struct stat finalDescriptorStatus {};
    struct stat finalPathStatus {};
    if (fstat(descriptor.get(), &finalDescriptorStatus) != 0 ||
            lstat(path.c_str(), &finalPathStatus) != 0 ||
            !S_ISREG(finalPathStatus.st_mode) ||
            !sameIdentity(identity, finalDescriptorStatus) ||
            !sameIdentity(identity, finalPathStatus)) {
        throw ConversionError(
            "existing report changed while being read: " + path
        );
    }
    descriptor.closeChecked("cannot close existing report", path);
    if (actual != expected) {
        throw ConversionError("report already exists: " + path);
    }
    return true;
}

bool pathExists(const std::string & path) {
    struct stat status {};
    if (lstat(path.c_str(), &status) == 0) {
        return true;
    }
    if (errno == ENOENT) {
        return false;
    }
    throw ConversionError(systemError("cannot inspect", path));
}

void requireAvailableDestination(const std::string & path, const std::string & label) {
    if (pathExists(path)) {
        throw ConversionError(label + " already exists: " + path);
    }
}

std::filesystem::path resolvedPublicationPath(const std::string & path) {
    const std::filesystem::path absolute =
        std::filesystem::absolute(path).lexically_normal();
    std::error_code error;
    const std::filesystem::path parent =
        std::filesystem::canonical(absolute.parent_path(), error);
    if (error) {
        throw ConversionError(
            "cannot resolve destination parent for " + path + ": " + error.message()
        );
    }
    return parent / absolute.filename();
}

void syncParentDirectory(const std::string & path) {
    std::filesystem::path parent =
        std::filesystem::absolute(path).parent_path();
    if (parent.empty()) {
        parent = ".";
    }
    int flags = O_RDONLY;
#if defined(O_DIRECTORY)
    flags |= O_DIRECTORY;
#endif
#if defined(O_CLOEXEC)
    flags |= O_CLOEXEC;
#endif
    const int descriptor = open(parent.c_str(), flags);
    if (descriptor < 0) {
        throw ConversionError(systemError("cannot open destination directory for", path));
    }
    if (fsync(descriptor) != 0) {
        const int savedError = errno;
        close(descriptor);
        errno = savedError;
        throw ConversionError(systemError("cannot fsync destination directory for", path));
    }
    if (close(descriptor) != 0) {
        throw ConversionError(systemError("cannot close destination directory for", path));
    }
}

class AtomicOutput final {
public:
    AtomicOutput(
        std::string finalPath,
        std::string label,
        bool allowExistingFinal = false
    ) : finalPath_(std::move(finalPath)), label_(std::move(label)) {
        if (!allowExistingFinal) {
            requireAvailableDestination(finalPath_, label_);
        }
        std::string pattern = finalPath_ + ".tmp.XXXXXX";
        std::vector<char> templateBytes(pattern.begin(), pattern.end());
        templateBytes.push_back('\0');
        const int descriptor = mkstemp(templateBytes.data());
        if (descriptor < 0) {
            throw ConversionError(systemError("cannot create temporary file for", finalPath_));
        }
        temporaryPath_ = templateBytes.data();
        file_ = fdopen(descriptor, "wb");
        if (!file_) {
            const int savedError = errno;
            close(descriptor);
            unlink(temporaryPath_.c_str());
            errno = savedError;
            throw ConversionError(systemError("cannot open temporary file for", finalPath_));
        }
    }

    ~AtomicOutput() {
        if (file_) {
            std::fclose(file_);
        }
        if (installed_) {
            rollbackInstalledBestEffort();
        }
        if (!temporaryPath_.empty()) {
            unlink(temporaryPath_.c_str());
        }
    }

    AtomicOutput(const AtomicOutput &) = delete;
    AtomicOutput & operator=(const AtomicOutput &) = delete;

    void write(const void * data, size_t size) {
        if (size == 0) {
            return;
        }
        if (!file_ || std::fwrite(data, 1, size, file_) != size) {
            throw ConversionError(systemError("cannot write temporary file for", finalPath_));
        }
    }

    void flushAndSync() {
        if (synced_) {
            return;
        }
        if (!file_ || std::fflush(file_) != 0) {
            throw ConversionError(systemError("cannot flush temporary file for", finalPath_));
        }
        if (fsync(fileno(file_)) != 0) {
            throw ConversionError(systemError("cannot fsync temporary file for", finalPath_));
        }
        synced_ = true;
    }

    void install() {
        flushAndSync();
        if (std::fclose(file_) != 0) {
            file_ = nullptr;
            throw ConversionError(systemError("cannot close temporary file for", finalPath_));
        }
        file_ = nullptr;
#if defined(__APPLE__)
        if (renamex_np(temporaryPath_.c_str(), finalPath_.c_str(), RENAME_EXCL) != 0) {
            if (errno == EEXIST) {
                throw ConversionError(label_ + " already exists: " + finalPath_);
            }
            throw ConversionError(systemError("cannot atomically install", finalPath_));
        }
        installed_ = true;
        temporaryPath_.clear();
#else
        if (link(temporaryPath_.c_str(), finalPath_.c_str()) != 0) {
            if (errno == EEXIST) {
                throw ConversionError(label_ + " already exists: " + finalPath_);
            }
            throw ConversionError(systemError("cannot atomically install", finalPath_));
        }
        installed_ = true;
        if (unlink(temporaryPath_.c_str()) != 0) {
            const ConversionError error(
                systemError(
                    "cannot unlink installed temporary file for",
                    finalPath_
                )
            );
            rollbackInstalledBestEffort();
            throw error;
        }
        temporaryPath_.clear();
#endif
        try {
            syncParentDirectory(finalPath_);
        } catch (...) {
            rollbackInstalledBestEffort();
            throw;
        }
    }

    void releaseInstalled() noexcept { installed_ = false; }

private:
    void rollbackInstalledBestEffort() noexcept {
        if (!installed_) {
            return;
        }
        const bool removed =
            unlink(finalPath_.c_str()) == 0 || errno == ENOENT;
        try {
            syncParentDirectory(finalPath_);
        } catch (...) {
        }
        if (removed) {
            installed_ = false;
        }
    }

    std::string finalPath_;
    std::string label_;
    std::string temporaryPath_;
    FILE * file_ = nullptr;
    bool synced_ = false;
    bool installed_ = false;
};

class HashedOutput final {
public:
    explicit HashedOutput(AtomicOutput & output) : output_(output) {}

    void write(const void * data, size_t size) {
        output_.write(data, size);
        hash_.update(data, size);
        if (size > std::numeric_limits<uint64_t>::max() - size_) {
            throw ConversionError("output size overflow");
        }
        size_ += size;
    }

    uint64_t size() const { return size_; }
    std::string finishHash() { return hexadecimal(hash_.finalize()); }

private:
    AtomicOutput & output_;
    Sha256 hash_;
    uint64_t size_ = 0;
};

uint32_t decodeLittleU32(const uint8_t * bytes) {
    return
        static_cast<uint32_t>(bytes[0]) |
        (static_cast<uint32_t>(bytes[1]) << 8) |
        (static_cast<uint32_t>(bytes[2]) << 16) |
        (static_cast<uint32_t>(bytes[3]) << 24);
}

int32_t decodeLittleI32(const uint8_t * bytes) {
    return static_cast<int32_t>(decodeLittleU32(bytes));
}

void encodeLittleI32(int32_t value, uint8_t * bytes) {
    const uint32_t raw = static_cast<uint32_t>(value);
    bytes[0] = static_cast<uint8_t>(raw);
    bytes[1] = static_cast<uint8_t>(raw >> 8);
    bytes[2] = static_cast<uint8_t>(raw >> 16);
    bytes[3] = static_cast<uint8_t>(raw >> 24);
}

int32_t readLittleI32(const InputFile & input, const std::string & description) {
    std::array<uint8_t, 4> bytes{};
    input.readExact(bytes.data(), bytes.size(), description);
    return decodeLittleI32(bytes.data());
}

uint32_t readLittleU32(const InputFile & input, const std::string & description) {
    std::array<uint8_t, 4> bytes{};
    input.readExact(bytes.data(), bytes.size(), description);
    return decodeLittleU32(bytes.data());
}

size_t checkedMultiply(size_t lhs, size_t rhs, const std::string & description) {
    if (lhs != 0 && rhs > std::numeric_limits<size_t>::max() / lhs) {
        throw ConversionError(description + " byte count overflows");
    }
    return lhs * rhs;
}

void checkedSkip(
    const InputFile & input,
    uint64_t count,
    int64_t sourceSize,
    const std::string & description
) {
    const int64_t position = input.tell();
    if (count > static_cast<uint64_t>(std::numeric_limits<int64_t>::max()) ||
            position > sourceSize ||
            static_cast<int64_t>(count) > sourceSize - position) {
        throw ConversionError("truncated " + description + " in " + input.path());
    }
    input.seek(position + static_cast<int64_t>(count));
}

struct ParsedPreamble {
    std::array<int32_t, kHparamCount> hparams{};
    int64_t tensorOffset = 0;
};

ParsedPreamble parsePreamble(const InputFile & input, int64_t sourceSize) {
    input.seek(0);
    if (readLittleU32(input, "model magic") != kModelMagic) {
        throw ConversionError("bad model magic in " + input.path());
    }

    std::array<int32_t, kHparamCount> hparams{};
    for (size_t index = 0; index < hparams.size(); ++index) {
        hparams[index] = readLittleI32(input, "model hyperparameters");
    }
    const int32_t nMel = readLittleI32(input, "mel-filter dimensions");
    const int32_t nFilterBank = readLittleI32(input, "mel-filter dimensions");
    if (nMel <= 0 || nFilterBank <= 0) {
        throw ConversionError("invalid mel-filter dimensions in " + input.path());
    }
    const size_t melElements = checkedMultiply(
        static_cast<size_t>(nMel),
        static_cast<size_t>(nFilterBank),
        "mel filter"
    );
    checkedSkip(
        input,
        checkedMultiply(melElements, sizeof(float), "mel filter"),
        sourceSize,
        "mel-filter payload"
    );

    const int32_t nWindow = readLittleI32(input, "window length");
    if (nWindow <= 0) {
        throw ConversionError("invalid window length in " + input.path());
    }
    checkedSkip(
        input,
        checkedMultiply(static_cast<size_t>(nWindow), sizeof(float), "window"),
        sourceSize,
        "window payload"
    );

    const int32_t durationCount = hparams[13];
    if (durationCount < 0) {
        throw ConversionError("invalid duration count in " + input.path());
    }
    checkedSkip(
        input,
        checkedMultiply(static_cast<size_t>(durationCount), sizeof(uint32_t), "durations"),
        sourceSize,
        "duration payload"
    );

    const int32_t tokenCount = readLittleI32(input, "token count");
    if (tokenCount < 0) {
        throw ConversionError("invalid token count in " + input.path());
    }
    for (int32_t index = 0; index < tokenCount; ++index) {
        const uint32_t length = readLittleU32(input, "token length");
        checkedSkip(input, length, sourceSize, "token bytes");
    }
    return {hparams, input.tell()};
}

struct TypeInfo {
    ggml_type type;
    std::string_view name;
};

TypeInfo sourceTypeInfo(int32_t typeId) {
    switch (typeId) {
        case GGML_TYPE_F32:
            return {GGML_TYPE_F32, "f32"};
        case GGML_TYPE_F16:
            return {GGML_TYPE_F16, "f16"};
        case GGML_TYPE_Q8_0:
            return {GGML_TYPE_Q8_0, "q8_0"};
        case GGML_TYPE_Q4_K:
            return {GGML_TYPE_Q4_K, "q4_K"};
        case GGML_TYPE_Q6_K:
            return {GGML_TYPE_Q6_K, "q6_K"};
        default:
            throw ConversionError("unsupported source tensor type " + std::to_string(typeId));
    }
}

TypeInfo targetTypeInfo(const std::string & name) {
    if (name == "q8_0") {
        return {GGML_TYPE_Q8_0, "q8_0"};
    }
    if (name == "q4_K") {
        return {GGML_TYPE_Q4_K, "q4_K"};
    }
    if (name == "q6_K") {
        return {GGML_TYPE_Q6_K, "q6_K"};
    }
    throw ConversionError("unsupported target type " + name);
}

struct NominalType {
    std::string name;
    int32_t encodedFtype;
};

NominalType nominalTypeInfo(const std::string & name) {
    if (name == "f32") {
        return {name, GGML_FTYPE_ALL_F32};
    }
    if (name == "f16") {
        return {name, GGML_FTYPE_MOSTLY_F16};
    }
    if (name == "q8_0") {
        return {
            name,
            GGML_QNT_VERSION * GGML_QNT_VERSION_FACTOR + GGML_FTYPE_MOSTLY_Q8_0,
        };
    }
    if (name == "q4_K") {
        return {
            name,
            GGML_QNT_VERSION * GGML_QNT_VERSION_FACTOR + GGML_FTYPE_MOSTLY_Q4_K,
        };
    }
    if (name == "q6_K") {
        return {
            name,
            GGML_QNT_VERSION * GGML_QNT_VERSION_FACTOR + GGML_FTYPE_MOSTLY_Q6_K,
        };
    }
    throw ConversionError("unsupported nominal type " + name);
}

size_t encodedPayloadBytes(
    ggml_type type,
    const std::array<int32_t, GGML_MAX_DIMS> & dimensions,
    const std::string & tensorName
) {
    const int64_t blockSize64 = ggml_blck_size(type);
    const size_t typeSize = ggml_type_size(type);
    if (blockSize64 <= 0 || typeSize == 0) {
        throw ConversionError("unsupported layout for tensor " + tensorName);
    }
    const size_t blockSize = static_cast<size_t>(blockSize64);
    if (dimensions[0] <= 0 || static_cast<size_t>(dimensions[0]) % blockSize != 0) {
        throw ConversionError(
            "ne[0]=" + std::to_string(dimensions[0]) +
            " is not divisible by " + std::string(ggml_type_name(type)) +
            " block size " + std::to_string(blockSize)
        );
    }
    size_t bytes = static_cast<size_t>(dimensions[0]) / blockSize;
    bytes = checkedMultiply(bytes, typeSize, "tensor " + tensorName);
    for (size_t index = 1; index < dimensions.size(); ++index) {
        if (dimensions[index] <= 0) {
            throw ConversionError("invalid dimensions for tensor " + tensorName);
        }
        bytes = checkedMultiply(
            bytes,
            static_cast<size_t>(dimensions[index]),
            "tensor " + tensorName
        );
    }
    return bytes;
}

bool validUtf8(const std::string & value) {
    for (size_t index = 0; index < value.size();) {
        const uint8_t first = static_cast<uint8_t>(value[index]);
        if (first == 0) {
            return false;
        }
        if (first < 0x80) {
            ++index;
            continue;
        }
        size_t continuationCount = 0;
        uint32_t codepoint = 0;
        uint32_t minimum = 0;
        if ((first & 0xe0) == 0xc0) {
            continuationCount = 1;
            codepoint = first & 0x1f;
            minimum = 0x80;
        } else if ((first & 0xf0) == 0xe0) {
            continuationCount = 2;
            codepoint = first & 0x0f;
            minimum = 0x800;
        } else if ((first & 0xf8) == 0xf0) {
            continuationCount = 3;
            codepoint = first & 0x07;
            minimum = 0x10000;
        } else {
            return false;
        }
        if (continuationCount > value.size() - index - 1) {
            return false;
        }
        for (size_t continuation = 1; continuation <= continuationCount; ++continuation) {
            const uint8_t byte = static_cast<uint8_t>(value[index + continuation]);
            if ((byte & 0xc0) != 0x80) {
                return false;
            }
            codepoint = (codepoint << 6) | (byte & 0x3f);
        }
        if (codepoint < minimum ||
                codepoint > 0x10ffff ||
                (codepoint >= 0xd800 && codepoint <= 0xdfff)) {
            return false;
        }
        index += continuationCount + 1;
    }
    return true;
}

bool validTsvName(const std::string & name) {
    return
        validUtf8(name) &&
        name.find('\t') == std::string::npos &&
        name.find('\r') == std::string::npos &&
        name.find('\n') == std::string::npos;
}

// Mechanically mirrors parakeet_tensor_uses_record_type plus the layer loops in
// parakeet_expected_tensor_names. Constructing concrete names makes decimal spelling,
// layer bounds, family, and suffix identical to the loader contract.
std::set<std::string> mixedV1LoaderAllowedNames(
    const std::array<int32_t, kHparamCount> & hparams
) {
    static constexpr std::array<std::string_view, 11> encoderSuffixes = {
        ".feed_forward1.linear1.weight",
        ".feed_forward1.linear2.weight",
        ".conv.pointwise_conv1.weight",
        ".conv.pointwise_conv2.weight",
        ".self_attn.linear_q.weight",
        ".self_attn.linear_k.weight",
        ".self_attn.linear_v.weight",
        ".self_attn.linear_out.weight",
        ".self_attn.linear_pos.weight",
        ".feed_forward2.linear1.weight",
        ".feed_forward2.linear2.weight",
    };
    const int32_t audioLayers = hparams[kAudioLayerHparamIndex];
    const int32_t predictionLayers =
        hparams[kPredictionLayerHparamIndex];
    if (audioLayers <= 0 || audioLayers > kMaximumAudioLayers) {
        throw ConversionError(
            "invalid n_audio_layer in model header: " +
            std::to_string(audioLayers)
        );
    }
    if (predictionLayers <= 0 ||
            predictionLayers > kMaximumPredictionLayers) {
        throw ConversionError(
            "invalid n_pred_layers in model header: " +
            std::to_string(predictionLayers)
        );
    }

    std::set<std::string> names = {
        "encoder.pre_encode.out.weight",
        "decoder.prediction.embed.weight",
        "joint.pred.weight",
        "joint.enc.weight",
        "joint.joint_net.2.weight",
    };
    for (int32_t layer = 0; layer < audioLayers; ++layer) {
        const std::string prefix =
            "encoder.layers." + std::to_string(layer);
        for (std::string_view suffix : encoderSuffixes) {
            names.emplace(prefix + std::string(suffix));
        }
    }
    for (int32_t layer = 0; layer < predictionLayers; ++layer) {
        const std::string index = std::to_string(layer);
        names.emplace(
            "decoder.prediction.dec_rnn.lstm.weight_ih_l" + index
        );
        names.emplace(
            "decoder.prediction.dec_rnn.lstm.weight_hh_l" + index
        );
    }
    return names;
}

struct ParsedRecord {
    std::array<uint8_t, 12> header;
    std::array<uint8_t, sizeof(int32_t) * GGML_MAX_DIMS> encodedDimensions{};
    size_t encodedDimensionsBytes = 0;
    std::array<int32_t, GGML_MAX_DIMS> dimensions{1, 1, 1, 1};
    std::string name;
    TypeInfo type;
    int32_t nDims;
    size_t payloadBytes;
    int64_t payloadOffset;
};

ParsedRecord readRecord(
    const InputFile & input,
    int64_t fileSize,
    const std::string & label
) {
    const int64_t recordOffset = input.tell();
    if (recordOffset < 0 || recordOffset > fileSize || fileSize - recordOffset < 12) {
        throw ConversionError(
            "truncated " + label + " tensor header at offset " +
            std::to_string(recordOffset)
        );
    }

    ParsedRecord record{};
    input.readExact(record.header.data(), record.header.size(), label + " tensor header");
    record.nDims = decodeLittleI32(record.header.data());
    const int32_t nameLength = decodeLittleI32(record.header.data() + 4);
    const int32_t typeId = decodeLittleI32(record.header.data() + 8);
    if (record.nDims < 0 ||
            record.nDims > GGML_MAX_DIMS ||
            nameLength <= 0 ||
            nameLength > kMaximumNameBytes) {
        throw ConversionError(
            "invalid " + label + " tensor header at offset " +
            std::to_string(recordOffset)
        );
    }
    record.type = sourceTypeInfo(typeId);

    record.encodedDimensionsBytes =
        static_cast<size_t>(record.nDims) * sizeof(int32_t);
    input.readExact(
        record.encodedDimensions.data(),
        record.encodedDimensionsBytes,
        label + " tensor dimensions"
    );
    for (int32_t index = 0; index < record.nDims; ++index) {
        record.dimensions[static_cast<size_t>(index)] = decodeLittleI32(
            record.encodedDimensions.data() +
                static_cast<size_t>(index) * sizeof(int32_t)
        );
        if (record.dimensions[static_cast<size_t>(index)] <= 0) {
            throw ConversionError(
                "invalid " + label + " tensor dimensions at offset " +
                std::to_string(recordOffset)
            );
        }
    }

    record.name.resize(static_cast<size_t>(nameLength));
    input.readExact(record.name.data(), record.name.size(), label + " tensor name");
    if (!validTsvName(record.name)) {
        throw ConversionError(
            "invalid " + label + " tensor name at offset " +
            std::to_string(recordOffset)
        );
    }

    record.payloadBytes = encodedPayloadBytes(
        record.type.type,
        record.dimensions,
        record.name
    );
    record.payloadOffset = input.tell();
    if (record.payloadBytes >
                static_cast<uint64_t>(std::numeric_limits<int64_t>::max()) ||
            record.payloadOffset > fileSize ||
            static_cast<int64_t>(record.payloadBytes) >
                fileSize - record.payloadOffset) {
        throw ConversionError(
            label + " tensor " + record.name + " payload exceeds bounds"
        );
    }
    return record;
}

uint64_t parsePositiveInteger(const std::string & value, const std::string & field) {
    uint64_t result = 0;
    const char * first = value.data();
    const char * last = first + value.size();
    const auto parsed = std::from_chars(first, last, result);
    if (value.empty() || parsed.ec != std::errc() || parsed.ptr != last || result == 0) {
        throw ConversionError("invalid " + field + " in plan");
    }
    return result;
}

bool isLowercaseHexDigest(const std::string & value) {
    if (value.size() != 64) {
        return false;
    }
    for (char character : value) {
        if (!((character >= '0' && character <= '9') ||
                (character >= 'a' && character <= 'f'))) {
            return false;
        }
    }
    return true;
}

struct PlanEntry {
    TypeInfo target;
    bool consumed = false;
};

struct Plan {
    uint64_t inputSize = 0;
    std::string inputSha256;
    uint64_t quantSourceSize = 0;
    std::string quantSourceSha256;
    NominalType nominal = nominalTypeInfo("f16");
    std::map<std::string, PlanEntry> entries;
};

Plan parsePlan(const std::string & path) {
    std::ifstream input(path);
    if (!input) {
        throw ConversionError("cannot open plan: " + path);
    }
    Plan plan;
    bool hasInputSize = false;
    bool hasInputSha = false;
    bool hasQuantSourceSize = false;
    bool hasQuantSourceSha = false;
    bool hasNominal = false;
    bool readingEntries = false;
    std::string line;
    size_t lineNumber = 0;
    if (!std::getline(input, line) || line != kPlanMagic) {
        throw ConversionError("invalid or missing plan v2 header");
    }
    ++lineNumber;
    while (std::getline(input, line)) {
        ++lineNumber;
        if (!line.empty() && line.back() == '\r') {
            throw ConversionError("carriage return is not valid in plan line " + std::to_string(lineNumber));
        }
        if (line.empty()) {
            throw ConversionError("blank line is not valid in plan line " + std::to_string(lineNumber));
        }
        if (!readingEntries && line.rfind("# ", 0) == 0) {
            const size_t separator = line.find('=');
            if (separator == std::string::npos || separator <= 2) {
                throw ConversionError("invalid plan header on line " + std::to_string(lineNumber));
            }
            const std::string key = line.substr(2, separator - 2);
            const std::string value = line.substr(separator + 1);
            if (key == "input_size_bytes") {
                if (hasInputSize) {
                    throw ConversionError("duplicate input_size_bytes in plan");
                }
                plan.inputSize = parsePositiveInteger(value, key);
                hasInputSize = true;
            } else if (key == "input_sha256") {
                if (hasInputSha) {
                    throw ConversionError("duplicate input_sha256 in plan");
                }
                if (!isLowercaseHexDigest(value)) {
                    throw ConversionError("invalid input_sha256 in plan");
                }
                plan.inputSha256 = value;
                hasInputSha = true;
            } else if (key == "quant_source_size_bytes") {
                if (hasQuantSourceSize) {
                    throw ConversionError("duplicate quant_source_size_bytes in plan");
                }
                plan.quantSourceSize = parsePositiveInteger(value, key);
                hasQuantSourceSize = true;
            } else if (key == "quant_source_sha256") {
                if (hasQuantSourceSha) {
                    throw ConversionError("duplicate quant_source_sha256 in plan");
                }
                if (!isLowercaseHexDigest(value)) {
                    throw ConversionError("invalid quant_source_sha256 in plan");
                }
                plan.quantSourceSha256 = value;
                hasQuantSourceSha = true;
            } else if (key == "nominal_type") {
                if (hasNominal) {
                    throw ConversionError("duplicate nominal_type in plan");
                }
                plan.nominal = nominalTypeInfo(value);
                hasNominal = true;
            } else {
                throw ConversionError("unknown plan header " + key);
            }
            continue;
        }

        readingEntries = true;
        if (line[0] == '#') {
            throw ConversionError("plan headers must precede entries");
        }
        const size_t separator = line.find('\t');
        if (separator == std::string::npos || line.find('\t', separator + 1) != std::string::npos) {
            throw ConversionError("plan entry must contain exactly two TSV fields on line " + std::to_string(lineNumber));
        }
        const std::string name = line.substr(0, separator);
        const std::string targetName = line.substr(separator + 1);
        if (name.empty() ||
                name.size() > static_cast<size_t>(kMaximumNameBytes) ||
                !validTsvName(name)) {
            throw ConversionError("invalid plan tensor name on line " + std::to_string(lineNumber));
        }
        PlanEntry entry{targetTypeInfo(targetName), false};
        if (!plan.entries.emplace(name, entry).second) {
            throw ConversionError("duplicate plan tensor " + name);
        }
    }
    if (!input.eof()) {
        throw ConversionError("cannot read plan: " + path);
    }
    if (!hasInputSize) {
        throw ConversionError("missing input_size_bytes in plan");
    }
    if (!hasInputSha) {
        throw ConversionError("missing input_sha256 in plan");
    }
    if (!hasQuantSourceSize) {
        throw ConversionError("missing quant_source_size_bytes in plan");
    }
    if (!hasQuantSourceSha) {
        throw ConversionError("missing quant_source_sha256 in plan");
    }
    if (!hasNominal) {
        throw ConversionError("missing nominal_type in plan");
    }
    return plan;
}


void copyExact(
    const InputFile & input,
    HashedOutput & output,
    uint64_t byteCount,
    std::vector<uint8_t> & buffer,
    const std::string & description
) {
    while (byteCount > 0) {
        const size_t count = static_cast<size_t>(
            byteCount < buffer.size() ? byteCount : buffer.size()
        );
        input.readExact(buffer.data(), count, description);
        output.write(buffer.data(), count);
        byteCount -= count;
    }
}

struct RecordReport {
    size_t index;
    std::string name;
    int32_t nDims;
    std::string shape;
    std::string inputType;
    std::string quantSourceType;
    std::string targetType;
    size_t inputBytes;
    size_t quantSourceBytes;
    size_t targetBytes;
};

std::string shapeString(
    int32_t nDims,
    const std::array<int32_t, GGML_MAX_DIMS> & dimensions
) {
    if (nDims == 0) {
        return "-";
    }
    std::ostringstream output;
    for (int32_t index = 0; index < nDims; ++index) {
        if (index != 0) {
            output << 'x';
        }
        output << dimensions[static_cast<size_t>(index)];
    }
    return output.str();
}

std::string renderReport(
    const Plan & plan,
    const std::string & inputPath,
    const std::string & quantSourcePath,
    const std::string & inputSha256,
    const std::string & quantSourceSha256,
    const std::string & outputPath,
    uint64_t outputSize,
    const std::string & outputSha256,
    const std::vector<RecordReport> & records
) {
    const auto validPathField = [](const std::string & value) {
        return
            value.size() <= kMaximumReportPathBytes &&
            value.find('\r') == std::string::npos &&
            value.find('\n') == std::string::npos;
    };
    if (!validPathField(inputPath) ||
            !validPathField(quantSourcePath) ||
            !validPathField(outputPath)) {
        throw ConversionError(
            "report path field exceeds or violates the report schema"
        );
    }
    if (records.size() > kMaximumTensorRecords ||
            inputSha256.size() != 64 ||
            quantSourceSha256.size() != 64 ||
            outputSha256.size() != 64 ||
            plan.nominal.name.size() > 4) {
        throw ConversionError(
            "internal conversion report exceeds its schema bounds"
        );
    }
    std::ostringstream report;
    report << kReportMagic << '\n';
    report << "# input_path=" << inputPath << '\n';
    report << "# input_size_bytes=" << plan.inputSize << '\n';
    report << "# input_sha256=" << inputSha256 << '\n';
    report << "# quant_source_path=" << quantSourcePath << '\n';
    report << "# quant_source_size_bytes=" << plan.quantSourceSize << '\n';
    report << "# quant_source_sha256=" << quantSourceSha256 << '\n';
    report << "# nominal_type=" << plan.nominal.name << '\n';
    report << "# output_path=" << outputPath << '\n';
    report << "# output_size_bytes=" << outputSize << '\n';
    report << "# output_sha256=" << outputSha256 << '\n';
    report << kReportColumns;
    for (const RecordReport & record : records) {
        if (record.index >= kMaximumTensorRecords ||
                record.name.size() >
                    static_cast<size_t>(kMaximumNameBytes) ||
                record.nDims < 0 ||
                record.nDims > GGML_MAX_DIMS ||
                record.shape.size() > 43 ||
                record.inputType.size() > 4 ||
                record.quantSourceType.size() > 4 ||
                record.targetType.size() > 4) {
            throw ConversionError(
                "internal conversion report row exceeds its schema bounds"
            );
        }
        report << record.index << '\t'
               << record.name << '\t'
               << record.nDims << '\t'
               << record.shape << '\t'
               << record.inputType << '\t'
               << record.quantSourceType << '\t'
               << record.targetType << '\t'
               << record.inputBytes << '\t'
               << record.quantSourceBytes << '\t'
               << record.targetBytes << '\n';
    }
    std::string result = report.str();
    if (result.size() > kMaximumReportBytes) {
        throw ConversionError(
            "internal conversion report exceeds its size bound"
        );
    }
    return result;
}

struct Arguments {
    std::string input;
    std::string quantSource;
    std::string plan;
    std::string output;
    std::string report;
};

std::string usage() {
    return
        "usage: parakeet-mixed-quantize --input F16_MODEL --quant-source F32_MODEL "
        "--plan PLAN.tsv --output MODEL [--report REPORT.tsv]";
}

Arguments parseArguments(int argc, char ** argv) {
    Arguments arguments;
    for (int index = 1; index < argc; ++index) {
        const std::string option = argv[index];
        if (option == "--help") {
            std::cout << usage() << '\n';
            std::exit(0);
        }
        if (option != "--input" &&
                option != "--quant-source" &&
                option != "--plan" &&
                option != "--output" &&
                option != "--report") {
            throw ConversionError("unknown argument " + option + "\n" + usage());
        }
        if (index + 1 >= argc) {
            throw ConversionError("missing value for " + option + "\n" + usage());
        }
        std::string * destination = nullptr;
        if (option == "--input") {
            destination = &arguments.input;
        } else if (option == "--quant-source") {
            destination = &arguments.quantSource;
        } else if (option == "--plan") {
            destination = &arguments.plan;
        } else if (option == "--output") {
            destination = &arguments.output;
        } else {
            destination = &arguments.report;
        }
        if (!destination->empty()) {
            throw ConversionError("duplicate argument " + option);
        }
        *destination = argv[++index];
        if (destination->empty()) {
            throw ConversionError("empty value for " + option);
        }
    }
    if (arguments.input.empty() ||
            arguments.quantSource.empty() ||
            arguments.plan.empty() ||
            arguments.output.empty()) {
        throw ConversionError(
            "--input, --quant-source, --plan, and --output are required\n" + usage()
        );
    }

    std::error_code inputError;
    const auto inputPath = std::filesystem::canonical(arguments.input, inputError);
    if (inputError) {
        throw ConversionError(
            "cannot resolve input " + arguments.input + ": " + inputError.message()
        );
    }
    std::error_code quantError;
    const auto quantSourcePath =
        std::filesystem::canonical(arguments.quantSource, quantError);
    if (quantError) {
        throw ConversionError(
            "cannot resolve quant source " + arguments.quantSource + ": " +
            quantError.message()
        );
    }
    const auto outputPath = resolvedPublicationPath(arguments.output);
    if (inputPath == quantSourcePath) {
        throw ConversionError("input and quant source must differ");
    }
    if (inputPath == outputPath || quantSourcePath == outputPath) {
        throw ConversionError("input, quant source, and output must differ");
    }
    if (!arguments.report.empty()) {
        const auto reportPath = resolvedPublicationPath(arguments.report);
        if (reportPath == outputPath ||
                reportPath == inputPath ||
                reportPath == quantSourcePath) {
            throw ConversionError("report path must differ from input, quant source, and output");
        }
    }
    return arguments;
}

class QuantizationCleanup final {
public:
    ~QuantizationCleanup() { ggml_quantize_free(); }
};

void convert(const Arguments & arguments) {
    Plan plan = parsePlan(arguments.plan);

    // Open both sources exactly once. All size checks, hashes, and record reads below
    // consume these descriptors; the paths are never re-opened, and identity/mtime is
    // re-verified after the payload pass so an in-place swap fails the conversion.
    InputFile input(arguments.input);
    InputFile quantSource(arguments.quantSource);
    if (input.isSameFileAs(quantSource)) {
        throw ConversionError("input and quant source must differ");
    }

    const int64_t inputSize = input.size();
    if (static_cast<uint64_t>(inputSize) != plan.inputSize) {
        throw ConversionError(
            "input size mismatch: plan=" + std::to_string(plan.inputSize) +
            " actual=" + std::to_string(inputSize)
        );
    }
    const std::string inputSha256 = input.hashContents();
    if (inputSha256 != plan.inputSha256) {
        throw ConversionError(
            "input SHA-256 mismatch: plan=" + plan.inputSha256 +
            " actual=" + inputSha256
        );
    }

    const int64_t quantSourceSize = quantSource.size();
    if (static_cast<uint64_t>(quantSourceSize) != plan.quantSourceSize) {
        throw ConversionError(
            "quant source size mismatch: plan=" +
            std::to_string(plan.quantSourceSize) +
            " actual=" + std::to_string(quantSourceSize)
        );
    }
    const std::string quantSourceSha256 = quantSource.hashContents();
    if (quantSourceSha256 != plan.quantSourceSha256) {
        throw ConversionError(
            "quant source SHA-256 mismatch: plan=" + plan.quantSourceSha256 +
            " actual=" + quantSourceSha256
        );
    }

    const ParsedPreamble inputModel = parsePreamble(input, inputSize);
    const ParsedPreamble quantModel =
        parsePreamble(quantSource, quantSourceSize);
    const int64_t inputTensorOffset = inputModel.tensorOffset;
    const int64_t quantTensorOffset = quantModel.tensorOffset;
    if (inputTensorOffset <
            static_cast<int64_t>(kFtypeOffset + sizeof(int32_t)) ||
            quantTensorOffset <
                static_cast<int64_t>(kFtypeOffset + sizeof(int32_t))) {
        throw ConversionError("invalid tensor-section offset");
    }
    if (inputTensorOffset != quantTensorOffset) {
        throw ConversionError(
            "quant source preamble size mismatch: input=" +
            std::to_string(inputTensorOffset) +
            " quant_source=" + std::to_string(quantTensorOffset)
        );
    }

    std::vector<uint8_t> inputPreamble(static_cast<size_t>(inputTensorOffset));
    std::vector<uint8_t> quantPreamble(static_cast<size_t>(quantTensorOffset));
    input.seek(0);
    quantSource.seek(0);
    input.readExact(inputPreamble.data(), inputPreamble.size(), "input preamble");
    quantSource.readExact(
        quantPreamble.data(),
        quantPreamble.size(),
        "quant source preamble"
    );
    const size_t afterFtype = kFtypeOffset + sizeof(int32_t);
    if (!std::equal(
            inputPreamble.begin(),
            inputPreamble.begin() + static_cast<ptrdiff_t>(kFtypeOffset),
            quantPreamble.begin()
        ) ||
            !std::equal(
                inputPreamble.begin() + static_cast<ptrdiff_t>(afterFtype),
                inputPreamble.end(),
                quantPreamble.begin() + static_cast<ptrdiff_t>(afterFtype)
            )) {
        throw ConversionError("quant source preamble does not match input");
    }
    const int32_t inputFtype = decodeLittleI32(
        inputPreamble.data() + kFtypeOffset
    );
    const int32_t quantSourceFtype = decodeLittleI32(
        quantPreamble.data() + kFtypeOffset
    );
    if (inputFtype != GGML_FTYPE_MOSTLY_F16) {
        throw ConversionError(
            "input global ftype must be f16, got " +
            std::to_string(inputFtype)
        );
    }
    if (quantSourceFtype != GGML_FTYPE_ALL_F32) {
        throw ConversionError(
            "quant source global ftype must be f32, got " +
            std::to_string(quantSourceFtype)
        );
    }

    const std::set<std::string> allowedPlanNames =
        mixedV1LoaderAllowedNames(inputModel.hparams);
    for (const auto & entry : plan.entries) {
        if (allowedPlanNames.find(entry.first) == allowedPlanNames.end()) {
            throw ConversionError(
                "plan selects tensor outside the mixed-v1 loader allowlist: " +
                entry.first
            );
        }
    }

    AtomicOutput atomicOutput(arguments.output, "output", /*allowExistingFinal=*/true);
    HashedOutput output(atomicOutput);
    encodeLittleI32(
        plan.nominal.encodedFtype,
        inputPreamble.data() + kFtypeOffset
    );
    output.write(inputPreamble.data(), inputPreamble.size());

    QuantizationCleanup quantizationCleanup;
    std::set<std::string> inputNames;
    std::set<std::string> quantSourceNames;
    std::vector<RecordReport> reportRecords;
    std::vector<uint8_t> copyBuffer(kCopyChunkBytes);
    std::vector<uint8_t> targetPayload;
    std::vector<float> floatValues;
    size_t recordIndex = 0;
    while (input.tell() < inputSize) {
        if (recordIndex >= kMaximumTensorRecords) {
            throw ConversionError(
                "tensor record count exceeds mixed-v1 loader maximum"
            );
        }
        if (quantSource.tell() >= quantSourceSize) {
            throw ConversionError(
                "quant source tensor count mismatch: ended before input"
            );
        }
        ParsedRecord inputRecord = readRecord(input, inputSize, "input");
        ParsedRecord quantRecord = readRecord(
            quantSource,
            quantSourceSize,
            "quant source"
        );
        if (!inputNames.insert(inputRecord.name).second) {
            throw ConversionError("duplicate input tensor " + inputRecord.name);
        }
        if (!quantSourceNames.insert(quantRecord.name).second) {
            throw ConversionError(
                "duplicate quant source tensor " + quantRecord.name
            );
        }
        if (inputRecord.name != quantRecord.name) {
            throw ConversionError(
                "quant source tensor name mismatch at index " +
                std::to_string(recordIndex) + ": input=" + inputRecord.name +
                " quant_source=" + quantRecord.name
            );
        }
        if (inputRecord.nDims != quantRecord.nDims ||
                inputRecord.dimensions != quantRecord.dimensions) {
            throw ConversionError(
                "quant source tensor shape mismatch for " + inputRecord.name +
                ": input=" +
                shapeString(inputRecord.nDims, inputRecord.dimensions) +
                " quant_source=" +
                shapeString(quantRecord.nDims, quantRecord.dimensions)
            );
        }

        auto planned = plan.entries.find(inputRecord.name);
        if (planned == plan.entries.end()) {
            output.write(
                inputRecord.header.data(),
                inputRecord.header.size()
            );
            output.write(
                inputRecord.encodedDimensions.data(),
                inputRecord.encodedDimensionsBytes
            );
            output.write(inputRecord.name.data(), inputRecord.name.size());
            copyExact(
                input,
                output,
                inputRecord.payloadBytes,
                copyBuffer,
                "input tensor " + inputRecord.name + " payload"
            );
            quantSource.seek(
                quantRecord.payloadOffset +
                static_cast<int64_t>(quantRecord.payloadBytes)
            );
            reportRecords.push_back({
                recordIndex,
                inputRecord.name,
                inputRecord.nDims,
                shapeString(inputRecord.nDims, inputRecord.dimensions),
                std::string(inputRecord.type.name),
                std::string(quantRecord.type.name),
                std::string(inputRecord.type.name),
                inputRecord.payloadBytes,
                quantRecord.payloadBytes,
                inputRecord.payloadBytes,
            });
        } else {
            if (inputRecord.nDims != 2) {
                throw ConversionError(
                    "selected tensor " + inputRecord.name + " is not 2-D"
                );
            }
            if (quantRecord.type.type != GGML_TYPE_F32) {
                throw ConversionError(
                    "selected quant source tensor " + inputRecord.name +
                    " must be f32, got " +
                    std::string(quantRecord.type.name)
                );
            }
            const TypeInfo targetType = planned->second.target;
            const size_t targetBytes = encodedPayloadBytes(
                targetType.type,
                inputRecord.dimensions,
                inputRecord.name
            );
            if (ggml_quantize_requires_imatrix(targetType.type)) {
                throw ConversionError(
                    "target type requires an importance matrix for tensor " +
                    inputRecord.name
                );
            }

            input.seek(
                inputRecord.payloadOffset +
                static_cast<int64_t>(inputRecord.payloadBytes)
            );
            const size_t elementCount = checkedMultiply(
                static_cast<size_t>(inputRecord.dimensions[0]),
                static_cast<size_t>(inputRecord.dimensions[1]),
                "tensor " + inputRecord.name
            );
            if (elementCount >
                    static_cast<size_t>(std::numeric_limits<int64_t>::max())) {
                throw ConversionError(
                    "tensor " + inputRecord.name +
                    " element count exceeds ggml limits"
                );
            }
            const size_t expectedF32Bytes = checkedMultiply(
                elementCount,
                sizeof(float),
                "tensor " + inputRecord.name
            );
            if (quantRecord.payloadBytes != expectedF32Bytes) {
                throw ConversionError(
                    "F32 quant source byte mismatch for tensor " +
                    inputRecord.name
                );
            }
            floatValues.resize(elementCount);
            quantSource.readExact(
                floatValues.data(),
                expectedF32Bytes,
                "quant source tensor " + inputRecord.name + " payload"
            );

            targetPayload.resize(targetBytes);
            const size_t actualBytes = ggml_quantize_chunk(
                targetType.type,
                floatValues.data(),
                targetPayload.data(),
                0,
                inputRecord.dimensions[1],
                inputRecord.dimensions[0],
                nullptr
            );
            if (actualBytes != targetBytes) {
                throw ConversionError(
                    "ggml_quantize_chunk returned " +
                    std::to_string(actualBytes) + " bytes for tensor " +
                    inputRecord.name + ", expected " +
                    std::to_string(targetBytes)
                );
            }

            std::array<uint8_t, 12> targetHeader = inputRecord.header;
            encodeLittleI32(
                static_cast<int32_t>(targetType.type),
                targetHeader.data() + 8
            );
            output.write(targetHeader.data(), targetHeader.size());
            output.write(
                inputRecord.encodedDimensions.data(),
                inputRecord.encodedDimensionsBytes
            );
            output.write(inputRecord.name.data(), inputRecord.name.size());
            output.write(targetPayload.data(), actualBytes);
            planned->second.consumed = true;
            reportRecords.push_back({
                recordIndex,
                inputRecord.name,
                inputRecord.nDims,
                shapeString(inputRecord.nDims, inputRecord.dimensions),
                std::string(inputRecord.type.name),
                std::string(quantRecord.type.name),
                std::string(targetType.name),
                inputRecord.payloadBytes,
                quantRecord.payloadBytes,
                actualBytes,
            });
        }
        ++recordIndex;
    }
    if (input.tell() != inputSize) {
        throw ConversionError(
            "input tensor parsing did not end at pinned EOF"
        );
    }
    if (quantSource.tell() != quantSourceSize) {
        throw ConversionError(
            "quant source tensor count mismatch: input ended first"
        );
    }
    for (const auto & entry : plan.entries) {
        if (!entry.second.consumed) {
            throw ConversionError(
                "plan tensor not found in input: " + entry.first
            );
        }
    }

    // Both sources must still be the exact files that were opened, sized, and hashed.
    input.verifyUnchanged();
    quantSource.verifyUnchanged();

    const uint64_t outputSize = output.size();
    const std::string outputSha256 = output.finishHash();
    const std::string reportText = renderReport(
        plan,
        arguments.input,
        arguments.quantSource,
        inputSha256,
        quantSourceSha256,
        arguments.output,
        outputSize,
        outputSha256,
        reportRecords
    );

    // Publication is two files, so one unavoidable crash window remains: a crash after the
    // model rename and before the report rename leaves a model without its report. Ordinary
    // error returns remain transactional: each newly renamed final retains rollback ownership
    // until the directory sync and the report file or stdout publication have all succeeded.
    atomicOutput.flushAndSync();
    const bool reportPreexisting =
        !arguments.report.empty() &&
        existingReportMatchesIfPresent(arguments.report, reportText);

    if (pathExists(arguments.output)) {
        InputFile existingOutput(arguments.output);
        if (existingOutput.size() != static_cast<int64_t>(outputSize) ||
                existingOutput.hashContents() != outputSha256) {
            throw ConversionError("output already exists: " + arguments.output);
        }
    } else {
        atomicOutput.install();
    }

    std::unique_ptr<AtomicOutput> reportOutput;
    if (!arguments.report.empty()) {
        if (!reportPreexisting) {
            reportOutput = std::make_unique<AtomicOutput>(
                arguments.report,
                "report",
                /*allowExistingFinal=*/true
            );
            reportOutput->write(reportText.data(), reportText.size());
            reportOutput->install();
        }
    } else {
        std::cout << reportText;
        std::cout.flush();
        if (!std::cout) {
            throw ConversionError(
                "cannot write conversion report to stdout"
            );
        }
    }

    if (reportOutput) {
        reportOutput->releaseInstalled();
    }
    atomicOutput.releaseInstalled();
}

}  // namespace

int main(int argc, char ** argv) {
    try {
        convert(parseArguments(argc, argv));
        return 0;
    } catch (const ConversionError & error) {
        std::cerr << "parakeet-mixed-quantize: " << error.what() << '\n';
        return 1;
    } catch (const std::exception & error) {
        std::cerr << "parakeet-mixed-quantize: unexpected error: " << error.what() << '\n';
        return 1;
    }
}
