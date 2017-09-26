#define _GNU_SOURCE
#include <dirent.h>		/* Defines DT_* constants */
#include <fcntl.h>
#include <stdio.h>
#include <unistd.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <sys/syscall.h>

#define handle_error(msg) \
		 do { perror(msg); exit(EXIT_FAILURE); } while (0)

struct linux_dirent {
	long				d_ino;
	off_t				d_off;
	unsigned short d_reclen;
	char				d_name[];
};

/* increasing the BUF_SIZE does not make this faster

1K BUF_SIZE
[jkstill@lestrade dir_test]$ time getdents/getdents audit_old | wc
4365741 21645836 275847541

real    0m16.415s
user    0m18.477s
sys     0m3.117s

8K BUF_SIZE
[jkstill@lestrade dir_test]$ time getdents/getdents audit_old | wc
4045031 20202641 260982848

real    0m15.125s
user    0m17.246s
sys     0m3.003s


16K BUF_SIZE
[jkstill@lestrade dir_test]$ time getdents/getdents audit_old | wc
4022491 20101211 259945982

real    0m15.141s
user    0m17.229s
sys     0m3.065s


32K BUF_SIZE
[jkstill@lestrade dir_test]$ time getdents/getdents audit_old | wc
4011241 20050586 259417232

real    0m15.308s
user    0m17.324s
sys     0m2.958s


64K BUF_SIZE
[jkstill@lestrade dir_test]$ time getdents/getdents audit_old | wc
4005621 20025296 259153092

real    0m15.248s
user    0m17.387s
sys     0m2.935s

128K BUF_SIZE
[jkstill@lestrade dir_test]$ time getdents/getdents audit_old | wc
4002813 20012660 259022519

real    0m15.674s
user    0m17.435s
sys     0m2.927s


1M BUF_SIZE

[jkstill@lestrade dir_test]$ time getdents/getdents audit_old | wc
4000355 20001599 258905941

real    0m17.900s
user    0m17.440s
sys     0m2.798s

5M BUF_SIZE
[jkstill@lestrade dir_test]$ time getdents/getdents audit_old | wc
4000075 20000339 258892501

real    0m17.755s
user    0m17.449s
sys     0m2.809s


*/

#define BUF_SIZE 1024*8

int
main(int argc, char *argv[])
{
	int fd, nread;
	char buf[BUF_SIZE];
	struct linux_dirent *d;
	int bpos;
	char d_type;

	fd = open(argc > 1 ? argv[1] : ".", O_RDONLY | O_DIRECTORY);
	if (fd == -1)
		 handle_error("open");

	for ( ; ; ) {
		 nread = syscall(SYS_getdents, fd, buf, BUF_SIZE);
		 if (nread == -1)
			  handle_error("getdents");

		 if (nread == 0)
			  break;

		 printf("--------------- nread=%d ---------------\n", nread);
		 printf("%10s %-12s %8s %20s %-s\n", "i-node#","file type","d_reclen","d_off","d_name");
		 for (bpos = 0; bpos < nread;) {
			  d = (struct linux_dirent *) (buf + bpos);
			  printf("%10ld ", d->d_ino);
			  d_type = *(buf + bpos + d->d_reclen - 1);
			  printf("%-12s ", (d_type == DT_REG) ?  "regular" :
									 (d_type == DT_DIR) ?  "directory" :
									 (d_type == DT_FIFO) ? "FIFO" :
									 (d_type == DT_SOCK) ? "socket" :
									 (d_type == DT_LNK) ?  "symlink" :
									 (d_type == DT_BLK) ?  "block dev" :
									 (d_type == DT_CHR) ?  "char dev" : "???");
			  printf("%8d %20lld %-s\n", d->d_reclen,
						 (long long) d->d_off, (char *) d->d_name);
			  bpos += d->d_reclen;
		 }
	}

	exit(EXIT_SUCCESS);
}


