/*
 * Cache maintenance
 *
 * Copyright (C) 2001 Deep Blue Solutions Ltd.
 * Copyright (C) 2012 ARM Ltd.
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

#include <linux/errno.h>
#include <linux/linkage.h>
#include <linux/init.h>
#include <asm/assembler.h>
#include <asm/cpufeature.h>
#include <asm/alternative.h>
#include <asm/asm-uaccess.h>

/*
 *	flush_icache_range(start,end)
 *
 *	Ensure that the I and D caches are coherent within specified region.
 *	This is typically used when code has been written to a memory region,
 *	and will be executed.
 *
 *	- start   - virtual start address of region
 *	- end     - virtual end address of region
 */
ENTRY(__flush_icache_range)
	/* FALLTHROUGH */

/*
 *	__flush_cache_user_range(start,end)
 *
 *	Ensure that the I and D caches are coherent within specified region.
 *	This is typically used when code has been written to a memory region,
 *	and will be executed.
 *
 *	- start   - virtual start address of region
 *	- end     - virtual end address of region
 */
ENTRY(__flush_cache_user_range)
	uaccess_ttbr0_enable x2, x3, x4
alternative_if ARM64_HAS_CACHE_IDC
	dsb	ishst
	b	7f
alternative_else_nop_endif
	dcache_line_size x2, x3
	sub	x3, x2, #1
	bic	x4, x0, x3
1:
user_alt 9f, "dc cvau, x4",  "dc civac, x4",  ARM64_WORKAROUND_CLEAN_CACHE
	add	x4, x4, x2
	cmp	x4, x1
	b.lo	1b
	dsb	ish

7:
alternative_if ARM64_HAS_CACHE_DIC
	isb
	b	8f
alternative_else_nop_endif
	invalidate_icache_by_line x0, x1, x2, x3, 9f
8:	mov	x0, #0
1:
	uaccess_ttbr0_disable x1, x2
	ret
9:
	mov	x0, #-EFAULT
	b	1b
ENDPROC(__flush_icache_range)
ENDPROC(__flush_cache_user_range)

/*
 *	invalidate_icache_range(start,end)
 *
 *	Ensure that the I cache is invalid within specified region.
 *
 *	- start   - virtual start address of region
 *	- end     - virtual end address of region
 */
ENTRY(invalidate_icache_range)
alternative_if ARM64_HAS_CACHE_DIC
	mov	x0, xzr
	isb
	ret
alternative_else_nop_endif

	uaccess_ttbr0_enable x2, x3, x4

	invalidate_icache_by_line x0, x1, x2, x3, 2f
	mov	x0, xzr
1:
	uaccess_ttbr0_disable x1, x2
	ret
2:
	mov	x0, #-EFAULT
	b	1b
ENDPROC(invalidate_icache_range)

/*
 *	__flush_dcache_area(kaddr, size)
 *
 *	Ensure that any D-cache lines for the interval [kaddr, kaddr+size)
 *	are cleaned and invalidated to the PoC.
 *
 *	- kaddr   - kernel address
 *	- size    - size in question
 */
ENTRY(__flush_dcache_area)
	dcache_by_line_op civac, sy, x0, x1, x2, x3
	ret
ENDPIPROC(__flush_dcache_area)

/*
 *	__clean_dcache_area_pou(kaddr, size)
 *
 * 	Ensure that any D-cache lines for the interval [kaddr, kaddr+size)
 * 	are cleaned to the PoU.
 *
 *	- kaddr   - kernel address
 *	- size    - size in question
 */
ENTRY(__clean_dcache_area_pou)
alternative_if ARM64_HAS_CACHE_IDC
	dsb	ishst
	ret
alternative_else_nop_endif
	dcache_by_line_op cvau, ish, x0, x1, x2, x3
	ret
ENDPROC(__clean_dcache_area_pou)

/*
 *	__inval_dcache_area(kaddr, size)
 *
 * 	Ensure that any D-cache lines for the interval [kaddr, kaddr+size)
 * 	are invalidated. Any partial lines at the ends of the interval are
 *	also cleaned to PoC to prevent data loss.
 *
 *	- kaddr   - kernel address
 *	- size    - size in question
 */
ENTRY(__inval_dcache_area)
	/* FALLTHROUGH */

/*
 *	__dma_inv_area(start, size)
 *	- start   - virtual start address of region
 *	- size    - size in question
 */
__dma_inv_area:
	add	x1, x1, x0
	dcache_line_size x2, x3
	sub	x3, x2, #1
	tst	x1, x3				// end cache line aligned?
	bic	x1, x1, x3
    /*
       x1 = x1 & ~x3, x1 = end address, x3 = size - 1
       ?
       */
	b.eq	1f
    /*
       1f로 분기
       tst의 연산 결과에 따른 flag를 보고
     */
	dc	civac, x1			// clean & invalidate D / U line
    /*
       주석 이외의 추가적인 해석은 하지못함
     */
1:	tst	x0, x3				// start cache line aligned?
    /*
       x0와 x3의 레지스터의 비트를 테스트? 테스트의 명확한 의미는?
     */

	bic	x0, x0, x3
    /*
       x0 = x0 & ~x3
     */
	b.eq	2f
    /*
       tst 연산 결과에 따라 2로 분기
     */
	dc	civac, x0			// clean & invalidate D / U line
	b	3f
    /*
       3으로 분기
     */
2:	dc	ivac, x0			// invalidate D / U line
3:	add	x0, x0, x2
    /*
       x0 = x0 + x2, x0 = bic에 의해 aligned 된 시작 주소, x2 = dcache_line_size
     */

	cmp	x0, x1
    /*
       x0와 x1를 비교
     */
	b.lo	2b
    /*
       https://m.blog.naver.com/hts0128/90068943230
       carry에 따라 위에 있는 2로 분기
     */
	dsb	sy
    /*
       이 명령어가 완료될 때까지 프로그램 순서에서 이 명령어 뒤에 있는 명령어는 실행되지 않습니다
     */

    /*
     */
	ret
ENDPIPROC(__inval_dcache_area)
ENDPROC(__dma_inv_area)

/*
 *	__clean_dcache_area_poc(kaddr, size)
 *
 * 	Ensure that any D-cache lines for the interval [kaddr, kaddr+size)
 * 	are cleaned to the PoC.
 *
 *	- kaddr   - kernel address
 *	- size    - size in question
 */
ENTRY(__clean_dcache_area_poc)
	/* FALLTHROUGH */

/*
 *	__dma_clean_area(start, size)
 *	- start   - virtual start address of region
 *	- size    - size in question
 */
__dma_clean_area:
	dcache_by_line_op cvac, sy, x0, x1, x2, x3
	ret
ENDPIPROC(__clean_dcache_area_poc)
ENDPROC(__dma_clean_area)

/*
 *	__clean_dcache_area_pop(kaddr, size)
 *
 * 	Ensure that any D-cache lines for the interval [kaddr, kaddr+size)
 * 	are cleaned to the PoP.
 *
 *	- kaddr   - kernel address
 *	- size    - size in question
 */
ENTRY(__clean_dcache_area_pop)
	alternative_if_not ARM64_HAS_DCPOP
	b	__clean_dcache_area_poc
	alternative_else_nop_endif
	dcache_by_line_op cvap, sy, x0, x1, x2, x3
	ret
ENDPIPROC(__clean_dcache_area_pop)

/*
 *	__dma_flush_area(start, size)
 *
 *	clean & invalidate D / U line
 *
 *	- start   - virtual start address of region
 *	- size    - size in question
 */
ENTRY(__dma_flush_area)
	dcache_by_line_op civac, sy, x0, x1, x2, x3
	ret
ENDPIPROC(__dma_flush_area)

/*
 *	__dma_map_area(start, size, dir)
 *	- start	- kernel virtual start address
 *	- size	- size of region
 *	- dir	- DMA direction
 */
ENTRY(__dma_map_area)
	cmp	w2, #DMA_FROM_DEVICE
	b.eq	__dma_inv_area
	b	__dma_clean_area
ENDPIPROC(__dma_map_area)

/*
 *	__dma_unmap_area(start, size, dir)
 *	- start	- kernel virtual start address
 *	- size	- size of region
 *	- dir	- DMA direction
 */
ENTRY(__dma_unmap_area)
	cmp	w2, #DMA_TO_DEVICE
	b.ne	__dma_inv_area
	ret
ENDPIPROC(__dma_unmap_area)
