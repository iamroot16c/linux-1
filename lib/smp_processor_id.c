// SPDX-License-Identifier: GPL-2.0
/*
 * lib/smp_processor_id.c
 *
 * DEBUG_PREEMPT variant of smp_processor_id().
 */
#include <linux/export.h>
#include <linux/kprobes.h>
#include <linux/sched.h>

notrace static nokprobe_inline
unsigned int check_preemption_disabled(const char *what1, const char *what2)
{
	int this_cpu = raw_smp_processor_id();
/*
    start_kernel - smp_setup_processor_id - set_my_cpu_offset 에서
    시스템 레지스터 tpidr_el1 또는 2 에 cpu 오프셋을 설정

    int 데이터타입, percpu 속성으로 선언된 cpu_number 변수의 메모리로부터
    시스템 레지스터 tpidr_el1 또는 2에 설정된 오프셋만큼 떨어진 위치의 메모리에서
    raw_smp_processor_id 값을 읽음

    #define raw_smp_processor_id() (*raw_cpu_ptr(&cpu_number))
    ->  #define raw_cpu_ptr(ptr)						\
        ({									\
            __verify_pcpu_ptr(ptr);						\
            arch_raw_cpu_ptr(ptr);						\
        })
        ->  #define arch_raw_cpu_ptr(ptr) SHIFT_PERCPU_PTR(ptr, __my_cpu_offset)
            ->  #define SHIFT_PERCPU_PTR(__p, __offset)					\
                	RELOC_HIDE((typeof(*(__p)) __kernel __force *)(__p), (__offset))
                    ->  #define RELOC_HIDE(ptr, off)						\
                        ({									\
                            unsigned long __ptr;						\
                            __asm__ ("" : "=r"(__ptr) : "0"(ptr));				\
                            (typeof(ptr)) (__ptr + (off));					\
                        })
            ->  #define __my_cpu_offset __my_cpu_offset()

    ->  DECLARE_PER_CPU_READ_MOSTLY(int, cpu_number);
        ->  #define DECLARE_PER_CPU_READ_MOSTLY(type, name)			\
            	DECLARE_PER_CPU_SECTION(type, name, "..read_mostly")
 */

	if (likely(preempt_count()))
		goto out;
/*
    likely:
        프로세서의 분기 예측 기능의 구현
        구현된 코드의 문법을 해석하는 것이 상당히 어렵고
        해석을 하지 않아도 문맥을 이해할 수 있는 것으로 보여서
        나중에 다시 보는 것으로 합의
 */
    //preempt_count는 현재 쓰레드의 preempt count 수를 return 함.

	if (irqs_disabled())
		goto out;
    // PMR(Priority Mask Register count) 에 설정된 값 보다 작은 priority의 interrupt가 실행 되지 못하도록 mask. daif bit에서 I flag를 set 하여 mask 함.


	/*
	 * Kernel threads bound to a single CPU can safely use
	 * smp_processor_id():
	 */
	if (cpumask_equal(&current->cpus_allowed, cpumask_of(this_cpu)))
		goto out;
    // cpumask_equal : 현재 사용되고 있는 CPU가, 현재 task가 사용할 수 있는 cpu 인지 확인
    //
    // cpumask_of(this_cpu) : this_cpu의 cpu id를 cpumask 비트맵 형식으로 set 해서 저장함
    // cpus_allowed : (do_set_cpu_allowed) current task (thread) 의 task 정보 중 cpumask struct type의 멤버
    //                task가 운영될 수 있는 cpu 정보가 저장되어 있음 
    //                (ref : http://jake.dothome.co.kr/sched_init, do_set_cpus_allowed() )

	/*
	 * It is valid to assume CPU-locality during early bootup:
	 */
	if (system_state < SYSTEM_SCHEDULING)
		goto out;
    // system이 booting state에 있는지 확인한다. 

	/*
	 * Avoid recursion:
	 */
	preempt_disable_notrace();
    //현재 실행중인  쓰레드의 preempt_count에 1을 더해서, 다른 쓰레드가 선점할 수 없도록 함

	if (!printk_ratelimit())
		goto out_enable;
    // 커널 로그 메시지가 5초에 10개 이상 나오지 못하도록 제한.

	printk(KERN_ERR "BUG: using %s%s() in preemptible [%08x] code: %s/%d\n",
		what1, what2, preempt_count() - 1, current->comm, current->pid);

	printk("caller is %pS\n", __builtin_return_address(0));
	dump_stack();

out_enable:
	preempt_enable_no_resched_notrace();
    //현재 쓰레드의 preempt count 수를 줄임.
out:
	return this_cpu;
}

notrace unsigned int debug_smp_processor_id(void)
{
	return check_preemption_disabled("smp_processor_id", "");
}
EXPORT_SYMBOL(debug_smp_processor_id);
NOKPROBE_SYMBOL(debug_smp_processor_id);

notrace void __this_cpu_preempt_check(const char *op)
{
	check_preemption_disabled("__this_cpu_", op);
}
EXPORT_SYMBOL(__this_cpu_preempt_check);
NOKPROBE_SYMBOL(__this_cpu_preempt_check);
