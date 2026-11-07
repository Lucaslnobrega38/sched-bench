// fault_touch — alvo cujos shadows dormem em falta de página com I/O.
//
//   fault_touch <segundos> <arquivo>
//
// Mapeia o arquivo MAP_PRIVATE e lê páginas espalhadas, sem nenhuma syscall no
// laço. Com o cache de páginas descartado (o script faz drop_caches em
// paralelo), um shadow que toque numa página que o alvo já tinha mapeado mas
// que o fork não copiou (VMA de arquivo sem anon_vma não tem PTE copiada)
// faz uma falta de leitura e dorme no I/O: não recebe tick como curr, que é
// o caso que o deadline do hrtimer e o teto de 1ms existem para cobrir.
#define _GNU_SOURCE
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

static double now(void)
{
	struct timespec ts;

	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts.tv_sec + ts.tv_nsec / 1e9;
}

int main(int argc, char **argv)
{
	struct stat st;
	volatile uint8_t *m;
	uint64_t sum = 0, k = 1, touched = 0;
	size_t pages;
	double end;
	int fd;

	if (argc != 3) { fprintf(stderr, "uso: %s <segundos> <arquivo>\n", argv[0]); return 2; }
	fd = open(argv[2], O_RDONLY);
	if (fd < 0 || fstat(fd, &st)) { perror("open"); return 2; }
	m = mmap(NULL, st.st_size, PROT_READ, MAP_PRIVATE, fd, 0);
	if (m == MAP_FAILED) { perror("mmap"); return 2; }
	pages = st.st_size / 4096;
	end = now() + atof(argv[1]);

	while (1) {
		k = k * 6364136223846793005ULL + 1442695040888963407ULL;
		sum += m[(k >> 20) % pages * 4096];
		touched++;
		if ((touched & 0xff) == 0 && now() > end)
			break;
	}
	printf("fault_touch: leituras=%llu soma=%llu\n",
	       (unsigned long long)touched, (unsigned long long)sum);
	return 0;
}
