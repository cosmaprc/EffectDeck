//  et_check.h
//  Tests/Native/link と driver の小さな検査台。assert と違って落ちずに数え、
//  どの検査がどの値で外れたかを出す。
//
//  1 本の実行ファイルに名前付きの検査を並べる。引数に名前を渡すとそれだけ走る
//  （CMakeLists.txt が ET_ENTRY(...) の行を拾って、検査ごとに ctest に登録する）。

#ifndef ET_CHECK_H
#define ET_CHECK_H

#include <stdio.h>
#include <string.h>

static int et_failures = 0;
static const char *et_current = "";

#define ET_CASE(name) static void case_##name(void)
#define ET_ENTRY(name) { #name, case_##name }

#define CHECK(cond)                                                                 \
    do {                                                                            \
        if (!(cond)) {                                                              \
            fprintf(stderr, "%s:%d: [%s] CHECK(%s)\n", __FILE__, __LINE__,          \
                    et_current, #cond);                                             \
            et_failures++;                                                          \
        }                                                                           \
    } while (0)

#define CHECK_EQ(a, b)                                                              \
    do {                                                                            \
        unsigned long long et_a_ = (unsigned long long)(a);                         \
        unsigned long long et_b_ = (unsigned long long)(b);                         \
        if (et_a_ != et_b_) {                                                       \
            fprintf(stderr, "%s:%d: [%s] CHECK_EQ(%s, %s): %llu != %llu\n",         \
                    __FILE__, __LINE__, et_current, #a, #b, et_a_, et_b_);          \
            et_failures++;                                                          \
        }                                                                           \
    } while (0)

#define CHECK_FEQ(a, b)                                                             \
    do {                                                                            \
        double et_a_ = (double)(a);                                                 \
        double et_b_ = (double)(b);                                                 \
        if (!(et_a_ == et_b_)) {                                                    \
            fprintf(stderr, "%s:%d: [%s] CHECK_FEQ(%s, %s): %.17g != %.17g\n",      \
                    __FILE__, __LINE__, et_current, #a, #b, et_a_, et_b_);          \
            et_failures++;                                                          \
        }                                                                           \
    } while (0)

typedef struct {
    const char *name;
    void (*fn)(void);
} et_case_t;

/// argv[1] があればその名前の検査だけ、無ければ全部。外れが 1 つでもあれば 1。
static inline int et_run(int argc, char **argv, const et_case_t *cases, size_t count) {
    const char *only = argc > 1 ? argv[1] : NULL;
    int ran = 0;
    for (size_t i = 0; i < count; i++) {
        if (only && strcmp(only, cases[i].name) != 0) continue;
        int before = et_failures;
        et_current = cases[i].name;
        cases[i].fn();
        printf("%s %s\n", et_failures == before ? "PASS" : "FAIL", cases[i].name);
        ran++;
    }
    if (ran == 0) {
        fprintf(stderr, "no such case: %s\n", only ? only : "(none)");
        return 2;
    }
    return et_failures == 0 ? 0 : 1;
}

/// 決まった列を出す乱数（線形合同）。検査が毎回同じ入力で走るように。
static unsigned et_lcg_state = 12345u;
static inline unsigned et_lcg(void) {
    et_lcg_state = et_lcg_state * 1103515245u + 12345u;
    return (et_lcg_state >> 16) & 0x7fffu;
}

#endif /* ET_CHECK_H */
