/*
 * Based on arch/arm/mm/proc.S
 *
 * Copyright (C) 2001 Deep Blue Solutions Ltd.
 * Copyright (C) 2012 ARM Ltd.
 * Author: Catalin Marinas <catalin.marinas@arm.com>
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License version 2 as
 * published by the Free Software Foundation.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.
 */

#include <linux/init.h>
#include <linux/linkage.h>
#include <asm/assembler.h>
#include <asm/asm-offsets.h>
#include <asm/hwcap.h>
#include <asm/pgtable.h>
#include <asm/pgtable-hwdef.h>
#include <asm/cpufeature.h>
#include <asm/alternative.h>

#ifdef CONFIG_ARM64_64K_PAGES
#define TCR_TG_FLAGS	TCR_TG0_64K | TCR_TG1_64K
#elif defined(CONFIG_ARM64_16K_PAGES)
#define TCR_TG_FLAGS	TCR_TG0_16K | TCR_TG1_16K
#else /* CONFIG_ARM64_4K_PAGES */
#define TCR_TG_FLAGS	TCR_TG0_4K | TCR_TG1_4K
#endif

#ifdef CONFIG_RANDOMIZE_BASE
#define TCR_KASLR_FLAGS	TCR_NFD1
#else
#define TCR_KASLR_FLAGS	0
#endif

#define TCR_SMP_FLAGS	TCR_SHARED

/* PTWs cacheable, inner/outer WBWA */
#define TCR_CACHE_FLAGS	TCR_IRGN_WBWA | TCR_ORGN_WBWA

#ifdef CONFIG_KASAN_SW_TAGS
#define TCR_KASAN_FLAGS TCR_TBI1
#else
#define TCR_KASAN_FLAGS 0
#endif

#define MAIR(attr, mt)	((attr) << ((mt) * 8))

#ifdef CONFIG_CPU_PM
/**
 * cpu_do_suspend - save CPU registers context
 *
 * x0: virtual address of context pointer
 */
ENTRY(cpu_do_suspend)
	mrs	x2, tpidr_el0
	mrs	x3, tpidrro_el0
	mrs	x4, contextidr_el1
	mrs	x5, cpacr_el1
	mrs	x6, tcr_el1
	mrs	x7, vbar_el1
	mrs	x8, mdscr_el1
	mrs	x9, oslsr_el1
	mrs	x10, sctlr_el1
alternative_if_not ARM64_HAS_VIRT_HOST_EXTN
	mrs	x11, tpidr_el1
alternative_else
	mrs	x11, tpidr_el2
alternative_endif
	mrs	x12, sp_el0
	stp	x2, x3, [x0]
	stp	x4, xzr, [x0, #16]
	stp	x5, x6, [x0, #32]
	stp	x7, x8, [x0, #48]
	stp	x9, x10, [x0, #64]
	stp	x11, x12, [x0, #80]
	ret
ENDPROC(cpu_do_suspend)

/**
 * cpu_do_resume - restore CPU register context
 *
 * x0: Address of context pointer
 */
	.pushsection ".idmap.text", "awx"
ENTRY(cpu_do_resume)
	ldp	x2, x3, [x0]
	ldp	x4, x5, [x0, #16]
	ldp	x6, x8, [x0, #32]
	ldp	x9, x10, [x0, #48]
	ldp	x11, x12, [x0, #64]
	ldp	x13, x14, [x0, #80]
	msr	tpidr_el0, x2
	msr	tpidrro_el0, x3
	msr	contextidr_el1, x4
	msr	cpacr_el1, x6

	/* Don't change t0sz here, mask those bits when restoring */
	mrs	x5, tcr_el1
	bfi	x8, x5, TCR_T0SZ_OFFSET, TCR_TxSZ_WIDTH

	msr	tcr_el1, x8
	msr	vbar_el1, x9

	/*
	 * __cpu_setup() cleared MDSCR_EL1.MDE and friends, before unmasking
	 * debug exceptions. By restoring MDSCR_EL1 here, we may take a debug
	 * exception. Mask them until local_daif_restore() in cpu_suspend()
	 * resets them.
	 */
	disable_daif
	msr	mdscr_el1, x10

	msr	sctlr_el1, x12
alternative_if_not ARM64_HAS_VIRT_HOST_EXTN
	msr	tpidr_el1, x13
alternative_else
	msr	tpidr_el2, x13
alternative_endif
	msr	sp_el0, x14
	/*
	 * Restore oslsr_el1 by writing oslar_el1
	 */
	ubfx	x11, x11, #1, #1
	msr	oslar_el1, x11
	reset_pmuserenr_el0 x0			// Disable PMU access from EL0

alternative_if ARM64_HAS_RAS_EXTN
	msr_s	SYS_DISR_EL1, xzr
alternative_else_nop_endif

	isb
	ret
ENDPROC(cpu_do_resume)
	.popsection
#endif

/*
 *	cpu_do_switch_mm(pgd_phys, tsk)
 *
 *	Set the translation table base pointer to be pgd_phys.
 *
 *	- pgd_phys - physical address of new TTB
 */
ENTRY(cpu_do_switch_mm)
	mrs	x2, ttbr1_el1
	mmid	x1, x1				// get mm->context.id
	phys_to_ttbr x3, x0

alternative_if ARM64_HAS_CNP
	cbz     x1, 1f                          // skip CNP for reserved ASID
	orr     x3, x3, #TTBR_CNP_BIT
1:
alternative_else_nop_endif
#ifdef CONFIG_ARM64_SW_TTBR0_PAN
	bfi	x3, x1, #48, #16		// set the ASID field in TTBR0
#endif
	bfi	x2, x1, #48, #16		// set the ASID
	msr	ttbr1_el1, x2			// in TTBR1 (since TCR.A1 is set)
	isb
	msr	ttbr0_el1, x3			// now update TTBR0
	isb
	b	post_ttbr_update_workaround	// Back to C code...
ENDPROC(cpu_do_switch_mm)

	.pushsection ".idmap.text", "awx"

.macro	__idmap_cpu_set_reserved_ttbr1, tmp1, tmp2
	adrp	\tmp1, empty_zero_page
	phys_to_ttbr \tmp2, \tmp1
	offset_ttbr1 \tmp2
	msr	ttbr1_el1, \tmp2
	isb
	tlbi	vmalle1
	dsb	nsh
	isb
.endm

/*
 * void idmap_cpu_replace_ttbr1(phys_addr_t ttbr1)
 *
 * This is the low-level counterpart to cpu_replace_ttbr1, and should not be
 * called by anything else. It can only be executed from a TTBR0 mapping.
 */
ENTRY(idmap_cpu_replace_ttbr1)
	save_and_disable_daif flags=x2

	__idmap_cpu_set_reserved_ttbr1 x1, x3

	offset_ttbr1 x0
	msr	ttbr1_el1, x0
	isb

	restore_daif x2

	ret
ENDPROC(idmap_cpu_replace_ttbr1)
	.popsection

#ifdef CONFIG_UNMAP_KERNEL_AT_EL0
	.pushsection ".idmap.text", "awx"

	.macro	__idmap_kpti_get_pgtable_ent, type
	dc	cvac, cur_\()\type\()p		// Ensure any existing dirty
	dmb	sy				// lines are written back before
	ldr	\type, [cur_\()\type\()p]	// loading the entry
	tbz	\type, #0, skip_\()\type	// Skip invalid and
	tbnz	\type, #11, skip_\()\type	// non-global entries
	.endm

	.macro __idmap_kpti_put_pgtable_ent_ng, type
	orr	\type, \type, #PTE_NG		// Same bit for blocks and pages
	str	\type, [cur_\()\type\()p]	// Update the entry and ensure
	dmb	sy				// that it is visible to all
	dc	civac, cur_\()\type\()p		// CPUs.
	.endm

/*
 * void __kpti_install_ng_mappings(int cpu, int num_cpus, phys_addr_t swapper)
 *
 * Called exactly once from stop_machine context by each CPU found during boot.
 */
__idmap_kpti_flag:
	.long	1
ENTRY(idmap_kpti_install_ng_mappings)
	cpu		.req	w0
	num_cpus	.req	w1
	swapper_pa	.req	x2
	swapper_ttb	.req	x3
	flag_ptr	.req	x4
	cur_pgdp	.req	x5
	end_pgdp	.req	x6
	pgd		.req	x7
	cur_pudp	.req	x8
	end_pudp	.req	x9
	pud		.req	x10
	cur_pmdp	.req	x11
	end_pmdp	.req	x12
	pmd		.req	x13
	cur_ptep	.req	x14
	end_ptep	.req	x15
	pte		.req	x16

	mrs	swapper_ttb, ttbr1_el1
	restore_ttbr1	swapper_ttb
	adr	flag_ptr, __idmap_kpti_flag

	cbnz	cpu, __idmap_kpti_secondary

	/* We're the boot CPU. Wait for the others to catch up */
	sevl
1:	wfe
	ldaxr	w18, [flag_ptr]
	eor	w18, w18, num_cpus
	cbnz	w18, 1b

	/* We need to walk swapper, so turn off the MMU. */
	pre_disable_mmu_workaround
	mrs	x18, sctlr_el1
	bic	x18, x18, #SCTLR_ELx_M
	msr	sctlr_el1, x18
	isb

	/* Everybody is enjoying the idmap, so we can rewrite swapper. */
	/* PGD */
	mov	cur_pgdp, swapper_pa
	add	end_pgdp, cur_pgdp, #(PTRS_PER_PGD * 8)
do_pgd:	__idmap_kpti_get_pgtable_ent	pgd
	tbnz	pgd, #1, walk_puds
next_pgd:
	__idmap_kpti_put_pgtable_ent_ng	pgd
skip_pgd:
	add	cur_pgdp, cur_pgdp, #8
	cmp	cur_pgdp, end_pgdp
	b.ne	do_pgd

	/* Publish the updated tables and nuke all the TLBs */
	dsb	sy
	tlbi	vmalle1is
	dsb	ish
	isb

	/* We're done: fire up the MMU again */
	mrs	x18, sctlr_el1
	orr	x18, x18, #SCTLR_ELx_M
	msr	sctlr_el1, x18
	isb

	/* Set the flag to zero to indicate that we're all done */
	str	wzr, [flag_ptr]
	ret

	/* PUD */
walk_puds:
	.if CONFIG_PGTABLE_LEVELS > 3
	pte_to_phys	cur_pudp, pgd
	add	end_pudp, cur_pudp, #(PTRS_PER_PUD * 8)
do_pud:	__idmap_kpti_get_pgtable_ent	pud
	tbnz	pud, #1, walk_pmds
next_pud:
	__idmap_kpti_put_pgtable_ent_ng	pud
skip_pud:
	add	cur_pudp, cur_pudp, 8
	cmp	cur_pudp, end_pudp
	b.ne	do_pud
	b	next_pgd
	.else /* CONFIG_PGTABLE_LEVELS <= 3 */
	mov	pud, pgd
	b	walk_pmds
next_pud:
	b	next_pgd
	.endif

	/* PMD */
walk_pmds:
	.if CONFIG_PGTABLE_LEVELS > 2
	pte_to_phys	cur_pmdp, pud
	add	end_pmdp, cur_pmdp, #(PTRS_PER_PMD * 8)
do_pmd:	__idmap_kpti_get_pgtable_ent	pmd
	tbnz	pmd, #1, walk_ptes
next_pmd:
	__idmap_kpti_put_pgtable_ent_ng	pmd
skip_pmd:
	add	cur_pmdp, cur_pmdp, #8
	cmp	cur_pmdp, end_pmdp
	b.ne	do_pmd
	b	next_pud
	.else /* CONFIG_PGTABLE_LEVELS <= 2 */
	mov	pmd, pud
	b	walk_ptes
next_pmd:
	b	next_pud
	.endif

	/* PTE */
walk_ptes:
	pte_to_phys	cur_ptep, pmd
	add	end_ptep, cur_ptep, #(PTRS_PER_PTE * 8)
do_pte:	__idmap_kpti_get_pgtable_ent	pte
	__idmap_kpti_put_pgtable_ent_ng	pte
skip_pte:
	add	cur_ptep, cur_ptep, #8
	cmp	cur_ptep, end_ptep
	b.ne	do_pte
	b	next_pmd

	/* Secondary CPUs end up here */
__idmap_kpti_secondary:
	/* Uninstall swapper before surgery begins */
	__idmap_cpu_set_reserved_ttbr1 x18, x17

	/* Increment the flag to let the boot CPU we're ready */
1:	ldxr	w18, [flag_ptr]
	add	w18, w18, #1
	stxr	w17, w18, [flag_ptr]
	cbnz	w17, 1b

	/* Wait for the boot CPU to finish messing around with swapper */
	sevl
1:	wfe
	ldxr	w18, [flag_ptr]
	cbnz	w18, 1b

	/* All done, act like nothing happened */
	offset_ttbr1 swapper_ttb
	msr	ttbr1_el1, swapper_ttb
	isb
	ret

	.unreq	cpu
	.unreq	num_cpus
	.unreq	swapper_pa
	.unreq	swapper_ttb
	.unreq	flag_ptr
	.unreq	cur_pgdp
	.unreq	end_pgdp
	.unreq	pgd
	.unreq	cur_pudp
	.unreq	end_pudp
	.unreq	pud
	.unreq	cur_pmdp
	.unreq	end_pmdp
	.unreq	pmd
	.unreq	cur_ptep
	.unreq	end_ptep
	.unreq	pte
ENDPROC(idmap_kpti_install_ng_mappings)
	.popsection
#endif

/*
 *	__cpu_setup
 *
 *	Initialise the processor for turning the MMU on.  Return in x0 the
 *	value of the SCTLR_EL1 register.
 */
	.pushsection ".idmap.text", "awx"
ENTRY(__cpu_setup)
	tlbi	vmalle1				// Invalidate local TLB
	/* tlb : 한번 방문했던 물리주소를 저장 
	   tlbi : tlb를 무효화 
	   vmalle1 : virtual memory all EL1
	   tlbi vmalle1 : EL1이하를 무효화
	*/
	dsb	nsh
	/* dsb : isb+dmb
	   cpu가 instruction 재배치를 막는다 
	   dsb nsh : 현재영역을 비공유 옵션으로 변경
	 */

	mov	x0, #3 << 20
	msr	cpacr_el1, x0			// Enable FP/ASIMD
	/*     
	부동소수점 연산/64비트를 넘는 데이터를 처리하는 
	instructtion에 대해서 trap하지 않는다
	 */
	mov	x0, #1 << 12			// Reset mdscr_el1 and disable
	msr	mdscr_el1, x0			// access to the DCC from EL0
	isb					// Unmask debug exceptions now,
	/* 이전 명령어가 끝나야 수행 됨 */
	enable_dbg				// since this is per-cpu
	/* arch/arm64/include/asm/assembler.h : 77
	   msr daifclr, #8
	   PSTATE의D비트를 '0' : 디버그 익셉션 발생을 허용
	   */
	reset_pmuserenr_el0 x0			// Disable PMU access from EL0
	/* arch/arm65/include/asm/assembler.h : 444
	   mrs x0, id_aa64dfr0_el1
	   sbfx x0, x0, #8, #4
	   // x0 = x0[11:8] // PMUver
	   cmp x0, #1
	   b.lt 9000f
	   msr pmuserenr_el0, xzr
	   // pmuserenr_el0 = 0
	   */
	/*
	 * Memory region attributes for LPAE:
	 *
	 *   n = AttrIndx[2:0]
	 *			n	MAIR
	 *   DEVICE_nGnRnE	000	00000000
	 *   DEVICE_nGnRE	001	00000100
	 *   DEVICE_GRE		010	00001100
	 *   NORMAL_NC		011	01000100
	 *   NORMAL		100	11111111
	 *   NORMAL_WT		101	10111011
	 */
	ldr	x5, =MAIR(0x00, MT_DEVICE_nGnRnE) | \
		     MAIR(0x04, MT_DEVICE_nGnRE) | \
		     MAIR(0x0c, MT_DEVICE_GRE) | \
		     MAIR(0x44, MT_NORMAL_NC) | \
		     MAIR(0xff, MT_NORMAL) | \
		     MAIR(0xbb, MT_NORMAL_WT)
			 /* x5 = 0xbbff440c0400
				교재151p 참조(메모리타입속성) 
				교재39,40p 참조
	ldr x5, #0xbbff440c0400 은 불가함(size over)
				*/
	msr	mair_el1, x5
    /*
       mair_el1 레지스터 -> attribute (속성)을 8개까지 할당 가능.
       페이지 엔트리에 3 비트의 인덱스 부분이 존재하는데, 그 attribute index 가
       mair_el1 레지스터의 각 속성을 가리키게 됨. (모기향 책 39p 참고)
     */


	/*
	 * Prepare SCTLR
	 */
	mov_q	x0, SCTLR_EL1_SET
	
    /*
       SCTLR_EL1 -> EL0, EL1 에 대한 시스템 동작을 관리
     */

    /*
	 * Set/prepare TCR and TTBR. We use 512GB (39-bit) address range for
	 * both user and kernel.
	 */

    /*
       지금까지 썼던 VA_BITS 는 48 이었는데 뜬금 39?
       -> 주석을 수정을 안한듯......
       -> 우리는 VA_BITS == 48 로 보고 진행하기로 함.
     */

	ldr	x10, =TCR_TxSZ(VA_BITS) | TCR_CACHE_FLAGS | TCR_SMP_FLAGS | \
			TCR_TG_FLAGS | TCR_KASLR_FLAGS | TCR_ASID16 | \
			TCR_TBI0 | TCR_A1 | TCR_KASAN_FLAGS
	tcr_clear_errata_bits x10, x9, x5

    /*
       TCR 레지스터 설정을 x10 에 대입 (관련 설정에 대한 개략적인 내용은 모기향책 73p 참조)
       tcr_clear_errata_bits -> FUJITSU HW 에 대한 에러 처리
     */


#ifdef CONFIG_ARM64_USER_VA_BITS_52
	ldr_l		x9, vabits_user
	sub		x9, xzr, x9
	add		x9, x9, #64

/*
   x9 = vabits_user 의 값
   ...
   x9 == #64 - vabits_user 

   t0sz -> 주소 상에서 앞에 있는 0의 개수 ex) 52 bits -> 상위 12 비트가 0, t0sz == 12
   -> 52bits 의 경우, 해당 값(t0sz 값)이 저장되어 있지 않으므로 여기서 계산.

   48bits 의 경우, idmap_t0sz 에 (64 - 48) (== 상위 0의 개수) 이 저장되어 있으므로
   idmap_t0sz 에서 그 값을 가져옴.
 */

#else
	ldr_l		x9, idmap_t0sz

/*
   idmap_t0sz 에 저장되어있는 48bits (VA_BITS) 의 t0sz 값(상위 0의 개수) 을 x9 에 넣음.
 */

#endif
	tcr_set_t0sz	x10, x9

/*
   tcr_set_t0sz x10, x9 -> x9 의 0 비트(offset) 부터 6 비트(width) 까지를 떼서, x10에 넣음.
   근데, 앞에 이미 tcr 설정에 대한 내용이 x10 에 저장되어 있는데, 
   이걸 왜 또함? 어떤 의미임?

   ****** 추후에 다시 체크해보기로 함. *********
 */ 

	/*
	 * Set the IPS bits in TCR_EL1.
	 */
	tcr_compute_pa_size x10, #TCR_IPS_SHIFT, x5, x6

/*
   assembler.h 에 macro 정의되어있음.

	.macro	tcr_compute_pa_size, tcr, pos, tmp0, tmp1
	mrs	\tmp0, ID_AA64MMFR0_E0L1
	// Narrow PARange to fit the PS field in TCR_ELx
    // tmp0 = ID_AA64MMFR0_E0L1 레지스터의 값

    ********************* 다음 모임 때, Ghidra 통해 ID_AA64MMFR0_E0L1 레지스터 값 확인해보기로 함. ***********************

	ubfx	\tmp0, \tmp0, #ID_AA64MMFR0_PARANGE_SHIFT, #3
    // 특정 비트를 뽑아냄. -> #ID ~ SHIFT 에서부터 #3 만큼을 tmp0에서 뽑아냄.
    // #ID_ ~ _SHIFT == 0
	mov	\tmp1, #ID_AA64MMFR0_PARANGE_MAX
    // #ID ~ MAX == 0x5
	cmp	\tmp0, \tmp1
    // cmp -> flag 설정을 함 (C, Z flag  -> C==1 && Z==0), tmp0 - tmp1 < 0 일 때, C(carry flag) 가 증가하므로
	csel	\tmp0, \tmp1, \tmp0, hi
    // 설정된 flag 값에 따라서, Hi condition 만족(tmp1 > tmp0 <=> source > destination)시, tmp0 에 tmp1 을 넣고,
    // 그렇지 않을시, tmp0 에 tmp0 을 넣음.
	bfi	\tcr, \tmp0, \pos, #3
    // tmp0 의 0 ~ 2 까지를 tcr 의 pos(== 32) 부터 3만큼 까지에 넣음.
    // -> tcr 의 32, 33, 34 에 해당 비트를 넣음.
	.endm

   #TCR 레지스터의 IPS 부분(32 ~ 34) 에 
 */

#ifdef CONFIG_ARM64_HW_AFDBM
	/*
	 * Enable hardware update of the Access Flags bit.
	 * Hardware dirty bit management is enabled later,
	 * via capabilities.
	 */
	mrs	x9, ID_AA64MMFR1_EL1
    // x9 = ID_AA64MMFR1_EL1
	and	x9, x9, #0xf
    // and 연산을 통해서 x9의 하위 4비트를 따와서 다시 x9에 대입
	cbz	x9, 1f
    // 만일, x9 값이 0라면 label 1 로 분기 (0 일시 not supported 이기 때문.)
	orr	x10, x10, #TCR_HA		// hardware Access flag update
    // TCR_HA : TCR 레지스터의 39 번째 bit
    // x10 에 TCR_HA bit 를 OR 연산한 뒤, x10 에 다시 대입(TCR 추가 설정을 해주는 격.)
1:
#endif	/* CONFIG_ARM64_HW_AFDBM */
	msr	tcr_el1, x10
    // x10 : 이때까지 설정한 TCR Flag 의 설정 값들 ** TCR : Translation Control Register (가상주소 - 물리주소 맵핑 시, TCR 레지스터의 설정값을 따라감.)
    // x10 에 저장된 값들을 tcr_el1 레지스터에 저장.
	ret					// return to head.S
ENDPROC(__cpu_setup)
