/*
 * pt.h - Minimal, stackless Protothreads for ARM/RISC-V/AVR
 * 
 * Based on Adam Dunkels' original Protothreads.
 * This version is optimized for C++ and the 8-bit parallel SERV core.
 * 
 * Performance: Zero stack overhead, single-jump context switching.
 */

#ifndef PT_H
#define PT_H

typedef unsigned short pt_line_t;

struct pt {
  pt_line_t lc;
};

#define PT_WAITING 0
#define PT_YIELDED 1
#define PT_EXITED  2
#define PT_ENDED   3

#define PT_BEGIN(pt) { pt_line_t pt_yield_flag = 1; switch((pt)->lc) { case 0:
#define PT_END(pt) } pt_yield_flag = 0; (pt)->lc = 0; return PT_ENDED; }

/* 
 * PT_WAIT_UNTIL: Yield until the condition is met.
 * Condition is evaluated every time the thread is polled.
 */
#define PT_WAIT_UNTIL(pt, condition) \
  do { \
    (pt)->lc = __LINE__; case __LINE__: \
    if(!(condition)) { \
      return PT_WAITING; \
    } \
  } while(0)

#define PT_WAIT_WHILE(pt, cond)  PT_WAIT_UNTIL((pt), !(cond))

/* 
 * PT_YIELD: Yield execution for one poll cycle.
 */
#define PT_YIELD(pt) \
  do { \
    pt_yield_flag = 0; \
    (pt)->lc = __LINE__; case __LINE__: \
    if(pt_yield_flag == 0) { \
      return PT_YIELDED; \
    } \
  } while(0)

#define PT_EXIT(pt) \
  do { \
    (pt)->lc = 0; \
    return PT_EXITED; \
  } while(0)

#define PT_INIT(pt)   (pt)->lc = 0

// Helper macro for calling a sub-protothread
#define PT_WAIT_THREAD(pt, thread) PT_WAIT_UNTIL((pt), (thread) != PT_WAITING)

#define PT_THREAD(name_args) int name_args

#endif /* PT_H */
