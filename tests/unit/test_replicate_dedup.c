/*
 * test_replicate_dedup.c — REQ-NET-12 unit test
 *
 * Valida la lógica del dedup LRU implementado en ubond.c. La
 * implementación se reproduce verbatim aquí (no se enlaza contra
 * ubond.c porque la función original es static — la dependencia con
 * el resto del runtime sería desproporcionada). El test estático
 * REQ-NET-12 (check 19) verifica que la lógica del ubond.c real
 * coincide con la documentada — ese es el "puente" entre este test
 * unitario y el binario.
 *
 * Compila con:   clang -O2 -Wall -o test_replicate_dedup test_replicate_dedup.c
 * Pasa si:       exit 0 + última línea "ALL_TESTS_PASSED".
 */
#include <stdio.h>
#include <stdint.h>
#include <string.h>

/* === Lógica replicada de ubond.c (REQ-NET-12 commit 01cc6eb) === */
#define REPLICATE_DEDUP_SIZE 1024
static uint64_t replicate_dedup_seen[REPLICATE_DEDUP_SIZE] = {0};
static uint16_t replicate_dedup_idx = 0;

static int ubond_replicate_dedup_check(uint64_t data_seq) {
    int i;
    if (data_seq == 0) return 0;
    for (i = 0; i < REPLICATE_DEDUP_SIZE; i++) {
        if (replicate_dedup_seen[i] == data_seq) return 1;
    }
    replicate_dedup_seen[replicate_dedup_idx] = data_seq;
    replicate_dedup_idx = (replicate_dedup_idx + 1) % REPLICATE_DEDUP_SIZE;
    return 0;
}

/* Reset state entre tests para aislamiento */
static void reset_state(void) {
    memset(replicate_dedup_seen, 0, sizeof(replicate_dedup_seen));
    replicate_dedup_idx = 0;
}

/* === Framework mínimo === */
static int failed = 0;
#define ASSERT_EQ(actual, expected, name) \
    do { \
        long long _a = (long long)(actual); \
        long long _e = (long long)(expected); \
        if (_a != _e) { \
            printf("FAIL: %s — got %lld, expected %lld\n", (name), _a, _e); \
            failed++; \
        } else { \
            printf("PASS: %s\n", (name)); \
        } \
    } while (0)

int main(void) {
    /* Test 1: data_seq=0 NUNCA se marca como visto.
     * Este caso cubre paquetes con reorder=0 (UDP no replicado): el
     * dedup debe ser pass-through para no afectarles. */
    reset_state();
    ASSERT_EQ(ubond_replicate_dedup_check(0), 0, "seq=0 first call returns 0");
    ASSERT_EQ(ubond_replicate_dedup_check(0), 0, "seq=0 repeated still returns 0");

    /* Test 2: primer seq válido → 0 (nuevo). */
    reset_state();
    ASSERT_EQ(ubond_replicate_dedup_check(1), 0, "first seq=1 is new");

    /* Test 3: segundo paquete con mismo seq → 1 (duplicado). */
    ASSERT_EQ(ubond_replicate_dedup_check(1), 1, "second seq=1 detected as dup");

    /* Test 4: tercer y cuarto duplicado siguen detectándose
     * (caso real: 3 enlaces replicando a la vez). */
    ASSERT_EQ(ubond_replicate_dedup_check(1), 1, "third seq=1 detected as dup");
    ASSERT_EQ(ubond_replicate_dedup_check(1), 1, "fourth seq=1 detected as dup");

    /* Test 5: seq distinto NO es duplicado aunque el anterior estuviera. */
    ASSERT_EQ(ubond_replicate_dedup_check(2), 0, "seq=2 is new (different from 1)");
    ASSERT_EQ(ubond_replicate_dedup_check(2), 1, "second seq=2 detected as dup");

    /* Test 6: wrap-around — tras WINDOW_SIZE+ entries distintas,
     * los más antiguos se evictan. Llenamos 1024 nuevos seqs y luego
     * uno más; el primer seq insertado (3) debería haber sido evictado. */
    reset_state();
    /* Inserta 3..1026 (1024 entries distintos, el buffer se llena) */
    for (uint64_t s = 3; s < 3 + REPLICATE_DEDUP_SIZE; s++) {
        ASSERT_EQ(ubond_replicate_dedup_check(s), 0, "fill: new seq inserted");
        if (failed >= 2) {
            printf("FAIL: aborted, fill loop produced false dup\n");
            return 1;
        }
    }
    /* En este punto: idx=0 (wrap), buffer contiene 3..1026 */
    /* seq=3 sigue en el buffer */
    ASSERT_EQ(ubond_replicate_dedup_check(3), 1, "seq=3 still in buffer at boundary");
    /* Insertamos 1027 — esto sobreescribe el slot 0 que tiene 3 */
    /* Wait: tras el wrap, el slot 0 ahora contiene 3 (el inserted en la primera iteración). Y _check(3) DEVOLVIÓ 1 sin avanzar el idx. */
    /* Insertar uno NUEVO debería sobreescribir slot 0 → eviccion 3. */
    ASSERT_EQ(ubond_replicate_dedup_check(9999), 0, "seq=9999 new (writes to slot 0, evicts seq=3)");
    /* seq=3 ya NO está en el buffer */
    ASSERT_EQ(ubond_replicate_dedup_check(3), 0, "seq=3 evicted after wrap");

    /* Test 7: secuencias muy grandes (uint64_t cerca del límite) — no overflow. */
    reset_state();
    uint64_t huge = 0xFFFFFFFFFFFFFFF0ULL;
    ASSERT_EQ(ubond_replicate_dedup_check(huge), 0, "huge seq new");
    ASSERT_EQ(ubond_replicate_dedup_check(huge), 1, "huge seq dup");

    if (failed > 0) {
        printf("---\n%d FAILURES\n", failed);
        return 1;
    }
    printf("---\nALL_TESTS_PASSED\n");
    return 0;
}
