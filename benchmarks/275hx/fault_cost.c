// fault_cost.c — custo por page-fault de cada tipo, no core em que for pinado.
// Separa "entrar/sair do kernel" de "o que o fault faz": se o custo de um COW
// de 4KB for parecido com o de religar a escrita, a operação quase não importa.
//
// Compilar: gcc -O2 -Wall -o fault_cost fault_cost.c
// Rodar:    taskset -c 8 ./fault_cost     (E-core)   |   taskset -c 0 ./fault_cost  (P-core)
// Opcional: ./fault_cost <paginas> <repeticoes>
#define _GNU_SOURCE
#include <sched.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include <unistd.h>
#include <sys/mman.h>
#include <sys/resource.h>
#include <sys/syscall.h>
#include <sys/wait.h>

#define PS 4096UL
static size_t NPAGES = 4096;
static int REPS = 15;

struct res { double ns; long flt; };

static double now_ns(void)
{
	struct timespec t;

	clock_gettime(CLOCK_MONOTONIC, &t);
	return t.tv_sec * 1e9 + t.tv_nsec;
}

static long minflt(void)
{
	struct rusage r;

	getrusage(RUSAGE_SELF, &r);
	return r.ru_minflt;
}

static char *region(void)
{
	char *p = mmap(NULL, NPAGES * PS, PROT_READ | PROT_WRITE,
		       MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);

	if (p == MAP_FAILED) {
		perror("mmap");
		exit(1);
	}
	madvise(p, NPAGES * PS, MADV_NOHUGEPAGE);	/* faults de 4KB */
	return p;
}

static void touch_w(char *p)
{
	volatile char *v = p;

	for (size_t i = 0; i < NPAGES; i++)
		v[i * PS] = 1;
}

static void touch_r(char *p)
{
	volatile char *v = p;
	volatile char sink = 0;

	for (size_t i = 0; i < NPAGES; i++)
		sink += v[i * PS];
	(void)sink;
}

/* mede só a fase entre t0 e t1; o preparo fica fora */
#define TIMED(stmt) do {			\
	long f0 = minflt();			\
	double t0 = now_ns();			\
	stmt;					\
	double t1 = now_ns();			\
	r.ns = t1 - t0;				\
	r.flt = minflt() - f0;			\
} while (0)

static struct res t_read_zero(void)
{
	struct res r;
	char *p = region();

	TIMED(touch_r(p));
	munmap(p, NPAGES * PS);
	return r;
}

static struct res t_first_touch(void)
{
	struct res r;
	char *p = region();

	TIMED(touch_w(p));
	munmap(p, NPAGES * PS);
	return r;
}

/* filho já morto: as PTEs do pai ficam sem escrita, mas a página é só dele */
static struct res t_wp_reuse(void)
{
	struct res r;
	char *p = region();
	pid_t c;

	touch_w(p);
	c = fork();
	if (c == 0)
		_exit(0);
	waitpid(c, NULL, 0);
	TIMED(touch_w(p));
	munmap(p, NPAGES * PS);
	return r;
}

/* filho vivo e parado: cada escrita do pai tem que alocar e copiar 4KB */
static struct res t_wp_cow(void)
{
	struct res r;
	char *p = region();
	int fd[2];
	pid_t c;
	char b;

	touch_w(p);
	if (pipe(fd)) {
		perror("pipe");
		exit(1);
	}
	c = fork();
	if (c == 0) {
		close(fd[1]);
		(void)!read(fd[0], &b, 1);
		_exit(0);
	}
	close(fd[0]);
	TIMED(touch_w(p));
	close(fd[1]);
	waitpid(c, NULL, 0);
	munmap(p, NPAGES * PS);
	return r;
}

/* referência da troca de modo: syscall vazia, sem fault */
static struct res t_syscall(void)
{
	struct res r;

	TIMED(for (size_t i = 0; i < NPAGES; i++) syscall(SYS_getppid));
	return r;
}

static int cmp(const void *a, const void *b)
{
	double x = *(const double *)a, y = *(const double *)b;

	return (x > y) - (x < y);
}

static void run(const char *name, struct res (*fn)(void), double *med_out)
{
	double ns[REPS], fl[REPS];

	fn();					/* descarta o primeiro */
	for (int i = 0; i < REPS; i++) {
		struct res r = fn();

		ns[i] = r.ns / NPAGES;
		fl[i] = (double)r.flt / NPAGES;
	}
	qsort(ns, REPS, sizeof(double), cmp);
	qsort(fl, REPS, sizeof(double), cmp);
	*med_out = ns[REPS / 2];
	printf("%-12s %9.0f %9.0f %9.0f %12.2f\n", name, ns[REPS / 2], ns[0],
	       ns[REPS - 1], fl[REPS / 2]);
}

int main(int argc, char **argv)
{
	double read_zero, first_touch, wp_reuse, wp_cow, sys;

	if (argc > 1)
		NPAGES = strtoul(argv[1], NULL, 0);
	if (argc > 2)
		REPS = atoi(argv[2]);

	printf("cpu=%d  paginas=%zu  repeticoes=%d\n", sched_getcpu(), NPAGES, REPS);
	printf("%-12s %9s %9s %9s %12s\n", "teste", "ns(med)", "ns(min)", "ns(max)", "faults/pag");
	run("syscall", t_syscall, &sys);
	run("read_zero", t_read_zero, &read_zero);
	run("wp_reuse", t_wp_reuse, &wp_reuse);
	run("first_touch", t_first_touch, &first_touch);
	run("wp_cow", t_wp_cow, &wp_cow);

	printf("\nrazoes: wp_cow/wp_reuse = %.2f   wp_reuse/syscall = %.2f   wp_cow/syscall = %.2f\n",
	       wp_cow / wp_reuse, wp_reuse / sys, wp_cow / sys);
	return 0;
}
