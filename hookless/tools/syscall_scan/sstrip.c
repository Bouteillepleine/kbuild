/*
 * sstrip.c — minimal, portable ELFkickers-style "super strip".
 *
 * Removes the section header table (which a normal `strip -s` leaves behind)
 * by zeroing e_shoff/e_shnum/e_shstrndx/e_shentsize and truncating the file to
 * the end of the last thing an actual loader reads (program headers + segment
 * file contents). For a freestanding static binary this reclaims the trailing
 * SHT + .shstrtab that `-s` cannot drop.
 *
 * Host tool: builds with any C compiler (tested: WinLibs mingw gcc on Windows).
 * Handles little-endian ELF32 and ELF64 by fixed field offsets — no <elf.h>.
 *
 *   sstrip <file> [<file> ...]      # strips each in place
 */
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>

static uint16_t rd16(const uint8_t *p) { return p[0] | (p[1] << 8); }
static uint32_t rd32(const uint8_t *p)
{ return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24); }
static uint64_t rd64(const uint8_t *p)
{ return (uint64_t)rd32(p) | ((uint64_t)rd32(p + 4) << 32); }
static void wr16(uint8_t *p, uint16_t v) { p[0] = v & 0xff; p[1] = (v >> 8) & 0xff; }
static void wr32(uint8_t *p, uint32_t v) { for (int i = 0; i < 4; i++) p[i] = (v >> (8 * i)) & 0xff; }
static void wr64(uint8_t *p, uint64_t v) { for (int i = 0; i < 8; i++) p[i] = (v >> (8 * i)) & 0xff; }

static int strip_one(const char *path)
{
	FILE *f = fopen(path, "rb");
	if (!f) { fprintf(stderr, "sstrip: %s: open failed\n", path); return 1; }
	fseek(f, 0, SEEK_END);
	long fsz = ftell(f);
	fseek(f, 0, SEEK_SET);
	uint8_t *b = malloc(fsz);
	if (!b || fread(b, 1, fsz, f) != (size_t)fsz) { fprintf(stderr, "sstrip: %s: read failed\n", path); fclose(f); free(b); return 1; }
	fclose(f);

	if (fsz < 64 || memcmp(b, "\177ELF", 4) != 0) { fprintf(stderr, "sstrip: %s: not an ELF\n", path); free(b); return 1; }
	if (b[5] != 1) { fprintf(stderr, "sstrip: %s: big-endian unsupported\n", path); free(b); return 1; }
	int is64 = (b[4] == 2);

	uint64_t phoff, newsz;
	uint16_t phnum, phentsize;
	if (is64) {
		phoff = rd64(b + 32);
		phentsize = rd16(b + 54);
		phnum = rd16(b + 56);
	} else {
		phoff = rd32(b + 28);
		phentsize = rd16(b + 42);
		phnum = rd16(b + 44);
	}

	/* smallest safe size: past the ELF header and the program header table */
	newsz = (is64 ? 64 : 52);
	uint64_t phend = phoff + (uint64_t)phnum * phentsize;
	if (phend > newsz) newsz = phend;

	/* extend to cover every byte any segment actually maps from the file */
	for (uint16_t i = 0; i < phnum; i++) {
		const uint8_t *ph = b + phoff + (uint64_t)i * phentsize;
		uint64_t off, fsize;
		if (is64) { off = rd64(ph + 8);  fsize = rd64(ph + 32); }
		else      { off = rd32(ph + 4);  fsize = rd32(ph + 16); }
		uint64_t end = off + fsize;
		if (end > newsz) newsz = end;
	}
	if (newsz > (uint64_t)fsz) newsz = fsz; /* never grow */

	/* drop the section header table */
	if (is64) {
		wr64(b + 40, 0);  /* e_shoff     */
		wr16(b + 58, 0);  /* e_shentsize */
		wr16(b + 60, 0);  /* e_shnum     */
		wr16(b + 62, 0);  /* e_shstrndx  */
	} else {
		wr32(b + 32, 0);
		wr16(b + 46, 0);
		wr16(b + 48, 0);
		wr16(b + 50, 0);
	}

	f = fopen(path, "wb");
	if (!f || fwrite(b, 1, newsz, f) != newsz) { fprintf(stderr, "sstrip: %s: write failed\n", path); if (f) fclose(f); free(b); return 1; }
	fclose(f);
	free(b);
	printf("sstrip: %s -> %llu bytes\n", path, (unsigned long long)newsz);
	return 0;
}

int main(int argc, char **argv)
{
	if (argc < 2) { fprintf(stderr, "usage: sstrip <file> [<file> ...]\n"); return 2; }
	int rc = 0;
	for (int i = 1; i < argc; i++) rc |= strip_one(argv[i]);
	return rc;
}
