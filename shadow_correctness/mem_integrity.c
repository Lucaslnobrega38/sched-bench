// mem_integrity — alvo e observador para o teste de memória dos shadows.
//
//   mem_integrity writer <segundos> <arquivo-compartilhado>
//   mem_integrity reader <segundos> <arquivo-compartilhado>
//
// O writer é single-thread, sem syscall no laço (é o que o torna elegível e
// sombreável): incrementa um contador numa região MAP_SHARED e mexe numa
// região privada. Um shadow que escrevesse na região compartilhada com o seu
// próprio contador, defasado, faria o contador andar para trás. O reader, em
// outro processo, vigia isso e que nenhuma palavra da região esteja à frente
// do contador.
// Uma checagem de si mesmo cobre a região privada.
#define _GNU_SOURCE
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

#define SHARED_BYTES (4UL << 20)
#define PRIV_BYTES (32UL << 20)
#define PRIV_WORDS (PRIV_BYTES / sizeof(uint64_t))

struct shared {
	volatile uint64_t seq;       // contador do writer
	volatile uint64_t seq_inv;   // ~seq, escrito logo depois
	volatile uint64_t words[1];  // o resto da região
};

static double now(void)
{
	struct timespec ts;

	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts.tv_sec + ts.tv_nsec / 1e9;
}

static struct shared *map_shared(const char *path, int create)
{
	int fd = open(path, create ? O_RDWR | O_CREAT : O_RDWR, 0600);
	void *p;

	if (fd < 0) { perror("open"); exit(2); }
	if (create && ftruncate(fd, SHARED_BYTES)) { perror("ftruncate"); exit(2); }
	p = mmap(NULL, SHARED_BYTES, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
	if (p == MAP_FAILED) { perror("mmap shared"); exit(2); }
	return p;
}

static int writer(double secs, const char *path)
{
	struct shared *sh = map_shared(path, 1);
	uint64_t *priv = mmap(NULL, PRIV_BYTES, PROT_READ | PROT_WRITE,
			      MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
	uint64_t k = 0, bad = 0, checked = 0;
	size_t nwords = SHARED_BYTES / sizeof(uint64_t);
	double end = now() + secs;

	if (priv == MAP_FAILED) { perror("mmap priv"); return 2; }
	// toca todas as páginas com 0: qualquer valor aqui tem de ser <= k, que é
	// o que a checagem abaixo exige (com priv[i] = i a própria inicialização
	// era contada como corrupção: 92 falsos positivos determinísticos)
	for (size_t i = 0; i < PRIV_WORDS; i += 512)
		priv[i] = 0;

	while (1) {
		k++;
		sh->seq = k;
		sh->seq_inv = ~k;
		sh->words[(k * 7919) % (nwords - 4)] = k;
		priv[(k * 104729) % PRIV_WORDS] = k;      // k = geração

		if ((k & 0x3fff) == 0) {                  // de tempos em tempos
			uint64_t j = (k * 31337) % PRIV_WORDS;

			// só é verificável o que foi escrito por este laço: valor <= k
			if (priv[j] > k) bad++;
			checked++;
			if (now() > end) break;
		}
	}
	printf("writer: iterações=%llu checagens_privadas=%llu privado_ruim=%llu\n",
	       (unsigned long long)k, (unsigned long long)checked, (unsigned long long)bad);
	return bad ? 1 : 0;
}

static int reader(double secs, const char *path)
{
	struct shared *sh;
	uint64_t last = 0, back = 0, torn = 0, reads = 0;
	double end = now() + secs + 0.5;

	for (int i = 0; i < 100; i++) {          // espera o writer criar o arquivo
		if (access(path, F_OK) == 0) break;
		usleep(50000);
	}
	sh = map_shared(path, 0);

	size_t nwords = SHARED_BYTES / sizeof(uint64_t);

	while (now() < end) {
		uint64_t a = sh->seq;
		// o writer grava words[] depois de seq: uma palavra nunca pode estar
		// à frente do seq lido depois dela
		uint64_t w = sh->words[(reads * 7919) % (nwords - 4)];
		uint64_t s2 = sh->seq;

		reads++;
		if (a < last) back++;                  // o contador andou para trás
		else last = a;
		if (w > s2) torn++;                    // palavra à frente do seq
	}
	printf("reader: leituras=%llu ultimo_seq=%llu para_tras=%llu a_frente=%llu\n",
	       (unsigned long long)reads, (unsigned long long)last,
	       (unsigned long long)back, (unsigned long long)torn);
	return (back || torn) ? 1 : 0;
}

int main(int argc, char **argv)
{
	if (argc != 4) {
		fprintf(stderr, "uso: %s writer|reader <segundos> <arquivo>\n", argv[0]);
		return 2;
	}
	if (!strcmp(argv[1], "writer")) return writer(atof(argv[2]), argv[3]);
	if (!strcmp(argv[1], "reader")) return reader(atof(argv[2]), argv[3]);
	return 2;
}
