#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

#include <sys/mman.h>
#include <sys/time.h>
#include <sys/xattr.h>

#include <fuse.h>
#include <ulockmgr.h>

#define UNUSED(x) (void)(x)
#define CHECK(call) ({int rc = call; if(rc<0) {return -errno;}rc;})

struct mtimedb {
    int fd;
    size_t fsize;
    const void *buf;
    uint32_t base_mtime;
};

static uint32_t mtimedb_read32(const struct mtimedb *db, unsigned offset)
{
    return *(uint32_t *)((uint8_t *)db->buf + offset);
}



static int mtimedb_init(struct mtimedb *db, const char *fname)
{
    struct stat st;
    int rc = open(fname, O_RDONLY);

    if(rc<0) {
        perror(fname);
        goto err_open;
    }
    db->fd = rc;
    rc = fstat(db->fd, &st);
    if(rc<0) {
        perror(fname);
        goto err_fstat;
    }
    db->fsize = st.st_size;
    db->buf = mmap(NULL, db->fsize, PROT_READ, MAP_SHARED, db->fd, 0);
    if(db->buf==MAP_FAILED) {
        perror(fname);
        rc = -1;
        goto err_mmap;
    }

    db->base_mtime = mtimedb_read32(db, 8);

    return 0;

err_mmap:
err_fstat:
    close(db->fd);
err_open:
    return rc;
}

static void mtimedb_uninit(struct mtimedb *db)
{
    munmap((void *)db->buf, db->fsize);
    close(db->fd);
    return;
}

static int mtimedb_compare_name(const struct mtimedb *db, unsigned offset, const char *path, unsigned *len)
{
    const unsigned char *db_name = (const unsigned char *)((uint8_t *)db->buf + offset);
    unsigned i;
    bool debug = false;
    int result = 0;
    for(i=0;;) {
        unsigned char db_ch = db_name[i];
        unsigned char path_ch = path[i];
        if(db_ch == path_ch) {
            if(db_ch == 0) {
                *len = i;
                break;
            }
            i++;
            continue;
        }
        if(path_ch=='/') {
            if( db_ch == 0 ) {
                *len = i;
                break;
            }
            path_ch = 0;
        }
        result = (int)db_ch - (int)path_ch;
        break;
    }
    if(debug) {
        printf("compare: path:%s name:%s -> %d\n", path, db_name, result);
    }
    return result;
}

struct name_entry {
    uint32_t name;
    uint32_t mtime;
    uint32_t children;
};

struct mtimedb_lookup_level_result {
    unsigned name_len;
    const struct name_entry *entry;
};

static int mtimedb_lookup_level(const struct mtimedb *db, const char *path, unsigned offset, struct mtimedb_lookup_level_result *result)
{
    unsigned dirs = mtimedb_read32(db, offset);
    unsigned i;
    struct name_entry *entry;
    bool debug=false;
    offset += 4;
    entry = (struct name_entry *)((uint8_t *)db->buf + offset);
    bool linear = false;

    if (linear) {
        for(i=0;i<dirs;i++) {
            unsigned name_offset = entry[i].name;
            if(debug) {
                printf("i=%u dirs=%u\n", i, dirs);
            }
            if(mtimedb_compare_name(db, name_offset, path, &result->name_len)==0) {
                result->entry = entry+i;
                return 0;
            }
        }
    } else {
        int left = 0;
        int right = (int)dirs - 1;
        for(;;) {
            unsigned name_offset;
            int middle;
            int cmp;
            if(left>right) {
                break;
            }
            middle = (left + right)/2;
            name_offset = entry[middle].name;
            cmp = mtimedb_compare_name(db, name_offset, path, &result->name_len);
            if(debug) {
                printf("range [%d,%d,%d] -> %d dirs=%u\n", left, middle, right, cmp, dirs);
            }
            if(cmp<0) {
                left = middle + 1;
            } else if (cmp>0) {
                right = middle - 1;
            } else {
                result->entry = entry+middle;
                return 0;
            }
        }
    }
    if(debug) {
        for(i=0;i<dirs;i++) {
            unsigned name_offset = entry[i].name;
            const char *db_name = (const char *)((uint8_t *)db->buf + name_offset);
            int cmp = mtimedb_compare_name(db, name_offset, path, &result->name_len);
            printf("%d %c %s %s\n", cmp, cmp>0?'>':(cmp < 0?'<':'='), path, db_name);
        }
    }
    return -1;
}

static int mtimedb_lookup(const struct mtimedb *db, const char *path, long *mtime)
{
    unsigned path_offset = 0;
    unsigned db_offset = 16;
    struct mtimedb_lookup_level_result result;
    bool debug = false;

    memset(&result, 0, sizeof(result));
    for(;;) {
        int rc = mtimedb_lookup_level(db, path+path_offset, db_offset, &result);
        if(debug) {
            printf("tc=%d offset:%#x match %s(%s)\n", rc, db_offset, path, path+(rc==0?result.name_len:0));
        }
        if(rc!=0) {
            return rc;
        }
        path_offset += result.name_len;
        if(path[path_offset]==0) {
            *mtime = (long)db->base_mtime + result.entry->mtime;
            break;
        }
        db_offset = result.entry->children;
        if(db_offset==0) {
            return -1;
        }
        path_offset ++;
    }
    return 0;
}

static const struct mtimedb *mtime_db=NULL;

static void passthru_update_mtime(const char *path, struct stat *st)
{
    bool debug = false;

    if(mtime_db) {
        long mtime=st->st_mtime;
        int rc = mtimedb_lookup(mtime_db, path, &mtime);
        if(debug) {
            fprintf(stderr, "path:%s rc:%d\n", path, rc);
        }
        if(rc==0) {
            memset(&st->st_mtime, 0, sizeof(*st) - offsetof(struct stat, st_mtime));
            st->st_mtime = mtime;
            st->st_atime = st->st_mtime;
            st->st_ctime = st->st_mtime;
        }
    }
    return;
}

static const char *get_local_path(const char *path)
{
    if(path[0]=='/') {
        path++;
        if(path[0]==0) {
            return ".";
        }
    }
    return path;
}

static int passthru_getattr(const char *path, struct stat *st)
{
    path = get_local_path(path);
    CHECK(lstat(path, st));
    passthru_update_mtime(path, st);
    return 0;
}


static int passthru_fgetattr(const char *path, struct stat *st,
                        struct fuse_file_info *fi)
{
    CHECK(fstat(fi->fh, st));
    path = get_local_path(path);
    passthru_update_mtime(path, st);
    return 0;
}

static int passthru_access(const char *path, int mask)
{
    path = get_local_path(path);
    CHECK(access(path, mask));
    return 0;
}

static int passthru_readlink(const char *path, char *buf, size_t size)
{
    int rc;
    path = get_local_path(path);
    rc =  CHECK(readlink(path, buf, size - 1));
    buf[rc] = '\0';
    return 0;
}

static int passthru_opendir(const char *path, struct fuse_file_info *fi)
{
    DIR *dp;
    path = get_local_path(path);

    dp = opendir(path);
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
    int rc;
    path = get_local_path(path);
    rc = CHECK(open(path, fi->flags));
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
    path = get_local_path(path);
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
    int rc;
    path = get_local_path(path);
    rc = CHECK(lgetxattr(path, name, value, size));
    return rc;
}

static int passthru_listxattr(const char *path, char *list, size_t size)
{
    int rc;
    path = get_local_path(path);
    rc = CHECK(llistxattr(path, list, size));
    return rc;
}

static int passthru_lock(const char *path, struct fuse_file_info *fi, int cmd,
                    struct flock *lock)
{
    UNUSED(path);
    return ulockmgr_op(fi->fh, cmd, lock, &fi->lock_owner, sizeof(fi->lock_owner));
}

static const char *root_path ="/";

static void *passthru_init(struct fuse_conn_info *conn)
{
    int rc;
    UNUSED(conn);
    rc = chdir(root_path);
    UNUSED(rc);
    return NULL;
}


static const struct fuse_operations interposer_ops = {
    .init       = passthru_init,
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
    struct mtimedb db;
    int rc;
    int cur_arg = 1;
    bool mtime_verbose = false;
    const char *db_path = NULL;
    bool mtime_lookup = false;

    for(;;) {
        const char *arg;
        if(cur_arg>=argc) {
            break;
        }
        arg = argv[cur_arg];
        if(cur_arg+1<argc && strcmp("--mtime",arg)==0) {
            db_path = argv[cur_arg+1];
            cur_arg+=2;
            continue;
        }
        if(cur_arg+1<argc && strcmp("--root",arg)==0) {
            root_path = argv[cur_arg+1];
            cur_arg+=2;
            continue;
        }
        if(strcmp("--mtime-verbose",arg)==0) {
            mtime_verbose = true;
            cur_arg++;
            continue;
        }
        if(strcmp("--mtime-lookup",arg)==0) {
            mtime_lookup=true;
            cur_arg++;
            continue;
        }
        break;
    }
    if(db_path) {
        rc  = mtimedb_init(&db, db_path);
        if(rc<0) {
            return 1;
        }
        mtime_db=&db;
    }
    rc = chdir(root_path);
    if(rc!=0) {
        perror(root_path);
        goto done;
    }

    if(mtime_lookup) {
        if(mtime_db==NULL) {
            fprintf(stderr,"must speficy mtime database first\n");
            return 1;
        }
        for(;;) {
            char buf[4096];
            const char *path = fgets(buf,sizeof(buf),stdin);
            long mtime;
            if(path==NULL) {
                break;
            }
            buf[strlen(path)-1]='\0';
            rc = mtimedb_lookup(&db, path, &mtime);
            if(mtime_verbose || rc<0) {
                printf("%s %s\n", path, rc==0?"match":"no match");
            }
            if(rc<0) {
                goto done;
            }
        }
        goto done;
    }
    if(cur_arg!=1) {
        argv[cur_arg-1] = argv[0];
    }
    rc = fuse_main(argc-(cur_arg-1), argv+(cur_arg-1), &interposer_ops, NULL);
done:
    if(mtime_db) {
        mtime_db = NULL;
        mtimedb_uninit(&db);
    }
    return rc;
}
