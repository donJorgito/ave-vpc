#!/bin/sh
# Validates ave-vpc.REQ-NET-47: corrige el deadlock del camino de envío que
# introdujo REQ-NET-46. Checks ESTÁTICOS sobre el patch y el árbol (no compila,
# no toca red): el patch existe y toca ubond.c, el semáforo busy_writing se
# incrementa como mucho una vez por lote, los dos ev_io_stop de do_send están
# guardados por !busy_writing, y el patch está integrado en el despliegue.
#
# shellcheck disable=SC1091
. "$(dirname "$0")/_lib_junit.sh"
junit_init "REQ-NET-47_busywriting_deadlock"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PATCH="${ROOT}/patches/ubond_busywriting_deadlock.patch"
SRC="${ROOT}/build/ubond/src/ubond.c"

# 1. El patch existe.
if [ -f "${PATCH}" ]; then
    junit_pass "patch_exists"
else
    junit_fail "patch_missing" "falta patches/ubond_busywriting_deadlock.patch"
    junit_finalize
fi

# 2. Toca src/ubond.c.
if grep -q "^diff --git a/src/ubond.c" "${PATCH}"; then
    junit_pass "patch_targets_ubond_c"
else
    junit_fail "patch_target_missing" "el patch debe tocar src/ubond.c"
fi

# 3. El patch introduce el contador por lote.
if grep -q "^+.*batch_sent" "${PATCH}"; then
    junit_pass "patch_adds_batch_counter"
else
    junit_fail "patch_no_batch_counter" "el patch debe introducir batch_sent"
fi

# 4. El patch añade la guarda !busy_writing al ev_io_stop desprotegido.
if grep -q "^+.*!tun->busy_writing && ev_is_active(&tun->io_write)" "${PATCH}"; then
    junit_pass "patch_guards_io_stop"
else
    junit_fail "patch_no_io_stop_guard" "falta la guarda !busy_writing en ev_io_stop"
fi

# 5. En el árbol: busy_writing++ aparece como mucho una vez en do_send, y
#    siempre bajo la guarda batch_sent. Si vuelve a haber un incremento por
#    paquete, el contador se infla y el enlace acaba mudo (el bug original).
if [ -f "${SRC}" ]; then
    n_inc="$(grep -c 'tun->busy_writing++' "${SRC}")"
    if [ "${n_inc}" -le 2 ] && grep -q 'if (!batch_sent)' "${SRC}"; then
        junit_pass "semaphore_incremented_per_batch"
    else
        junit_fail "semaphore_incremented_per_packet" \
            "busy_writing++ sin guarda batch_sent (encontrados: ${n_inc})"
    fi

    # 6. Ningún ev_io_stop de do_send queda sin la guarda !busy_writing.
    if [ "$(grep -c 'ev_io_stop(EV_A_ &tun->io_write)' "${SRC}")" \
         -eq "$(grep -c '!tun->busy_writing && ev_is_active(&tun->io_write)' "${SRC}")" ]; then
        junit_pass "all_io_stops_guarded"
    else
        junit_fail "unguarded_io_stop" \
            "hay ev_io_stop(io_write) sin guarda !busy_writing: puede matar el pump"
    fi
else
    junit_skip "semaphore_incremented_per_batch" "sin árbol build/ubond"
    junit_skip "all_io_stops_guarded" "sin árbol build/ubond"
fi

# 7. Integrado en 07b-setup-rpi-ubond.sh (despliegue Linux/servidor).
if grep -q "ubond_busywriting_deadlock" "${ROOT}/07b-setup-rpi-ubond.sh"; then
    junit_pass "integrated_in_07b"
else
    junit_fail "not_integrated_07b" "07b no aplica el patch REQ-NET-47"
fi

# 8. 07b admite FORCE_REBUILD: sin esto el patch no llega a una RPi que ya
#    tenga binario instalado (el Paso 2 se salta la compilación).
if grep -q 'FORCE_REBUILD' "${ROOT}/07b-setup-rpi-ubond.sh"; then
    junit_pass "07b_supports_force_rebuild"
else
    junit_fail "07b_no_force_rebuild" "07b no permite recompilar sobre RPi ya provisionada"
fi

junit_finalize
