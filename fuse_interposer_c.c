#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

#include <sys/time.h>
#include <sys/xattr.h>

#include <fuse.h>
#include <ulockmgr.h>

#define UNUSED(x) (void)(x)
#define CHECK(call) ({int rc = call; if(rc<0) {return -errno;}rc;})

static int passthru_getattr(const char *path, struct stat *st)
{
    CHECK(lstat(path, st));
    return 0;
}

static int passthru_fgetattr(const char *path, struct stat *st,
                        struct fuse_file_info *fi)
{
    CHECK(fstat(fi->fh, st));
    UNUSED(path);
    return 0;
}

static int passthru_access(const char *path, int mask)
{
    CHECK(access(path, mask));
    return 0;
}

static int passthru_readlink(const char *path, char *buf, size_t size)
{
    int rc =  CHECK(readlink(path, buf, size - 1));
    buf[rc] = '\0';
    return 0;
}

static int passthru_opendir(const char *path, struct fuse_file_info *fi)
{
    DIR *dp = opendir(path);
    if (dp == NULL) {
        return -errno;
    }
    fi->fh = (uintptr_t) dp;
    return 0;
}

static int passthru_readdir(const char *path, void *buf, fuse_fill_dir_t filler,
                       off_t offset, struct fuse_file_info *fi)
{
    DIR *dp = (DIR *) (uintptr_t) fi->fh;

    UNUSED(path);
    seekdir(dp, offset);
    for(;;) {
        struct stat st;
        struct dirent *de = readdir(dp);
        if(de==NULL) {
            break;
        }
        memset(&st, 0, sizeof(st));
        st.st_ino = de->d_ino;
        st.st_mode = de->d_type << 12;
        if (filler(buf, de->d_name, &st, telldir(dp))) {
            break;
        }
    }

    return 0;
}

static int passthru_releasedir(const char *path, struct fuse_file_info *fi)
{
    DIR *dp = (DIR *) (uintptr_t) fi->fh;
    UNUSED(path);
    CHECK(closedir(dp));
    return 0;
}

static int passthru_open(const char *path, struct fuse_file_info *fi)
{
    int rc = CHECK(open(path, fi->flags));
    fi->fh = rc;
    return 0;
}

static int passthru_read(const char *path, char *buf, size_t size, off_t offset,
                    struct fuse_file_info *fi)
{
    int rc = CHECK(pread(fi->fh, buf, size, offset));
    UNUSED(path);
    return rc;
}

static int passthru_statfs(const char *path, struct statvfs *st)
{
    CHECK(statvfs(path, st));
    return 0;
}

static int passthru_release(const char *path, struct fuse_file_info *fi)
{
    UNUSED(path);
    CHECK(close(fi->fh));
    return 0;
}

static int passthru_getxattr(const char *path, const char *name, char *value,
                    size_t size)
{
    int rc = CHECK(lgetxattr(path, name, value, size));
    return rc;
}

static int passthru_listxattr(const char *path, char *list, size_t size)
{
    int rc = CHECK(llistxattr(path, list, size));
    return rc;
}

static int passthru_lock(const char *path, struct fuse_file_info *fi, int cmd,
                    struct flock *lock)
{
    UNUSED(path);
    return ulockmgr_op(fi->fh, cmd, lock, &fi->lock_owner, sizeof(fi->lock_owner));
}

static const struct fuse_operations interposer_ops = {
    .access	    = passthru_access,
    .fgetattr	= passthru_fgetattr,
    .getattr	= passthru_getattr,
    .getxattr	= passthru_getxattr,
    .listxattr	= passthru_listxattr,
    .lock	    = passthru_lock,
    .open	    = passthru_open,
    .opendir	= passthru_opendir,
    .read	    = passthru_read,
    .readdir	= passthru_readdir,
    .readlink	= passthru_readlink,
    .release	= passthru_release,
    .releasedir	= passthru_releasedir,
    .statfs	    = passthru_statfs
};

int main(int argc, char *argv[])
{
    umask(0);
    return fuse_main(argc, argv, &interposer_ops, NULL);
}
