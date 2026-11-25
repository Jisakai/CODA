#pragma once
#include <algorithm>
#include <cstdlib>
#include <new>
static thread_local bool count_allocations=false;
static thread_local uint64_t allocation_count=0, deallocation_count=0;
static void *allocate(std::size_t n,std::size_t alignment=0) {
    if(count_allocations)++allocation_count;
    n=std::max<std::size_t>(n,1);
    void *p=alignment?std::aligned_alloc(alignment,((n+alignment-1)/alignment)*alignment):std::malloc(n);
    if(!p)throw std::bad_alloc();return p;
}
static void deallocate(void *p) noexcept {if(p&&count_allocations)++deallocation_count;std::free(p);}
void *operator new(std::size_t n){return allocate(n);}
void *operator new[](std::size_t n){return allocate(n);}
void *operator new(std::size_t n,std::align_val_t a){return allocate(n,static_cast<std::size_t>(a));}
void *operator new[](std::size_t n,std::align_val_t a){return allocate(n,static_cast<std::size_t>(a));}
void *operator new(std::size_t n,const std::nothrow_t&) noexcept {try{return allocate(n);}catch(...){return nullptr;}}
void *operator new[](std::size_t n,const std::nothrow_t&) noexcept {try{return allocate(n);}catch(...){return nullptr;}}
void *operator new(std::size_t n,std::align_val_t a,const std::nothrow_t&) noexcept {try{return allocate(n,static_cast<std::size_t>(a));}catch(...){return nullptr;}}
void *operator new[](std::size_t n,std::align_val_t a,const std::nothrow_t&) noexcept {try{return allocate(n,static_cast<std::size_t>(a));}catch(...){return nullptr;}}
void operator delete(void *p) noexcept {deallocate(p);}
void operator delete[](void *p) noexcept {deallocate(p);}
void operator delete(void *p,std::size_t) noexcept {deallocate(p);}
void operator delete[](void *p,std::size_t) noexcept {deallocate(p);}
void operator delete(void *p,std::align_val_t) noexcept {deallocate(p);}
void operator delete[](void *p,std::align_val_t) noexcept {deallocate(p);}
void operator delete(void *p,std::size_t,std::align_val_t) noexcept {deallocate(p);}
void operator delete[](void *p,std::size_t,std::align_val_t) noexcept {deallocate(p);}
void operator delete(void *p,const std::nothrow_t&) noexcept {deallocate(p);}
void operator delete[](void *p,const std::nothrow_t&) noexcept {deallocate(p);}
void operator delete(void *p,std::align_val_t,const std::nothrow_t&) noexcept {deallocate(p);}
void operator delete[](void *p,std::align_val_t,const std::nothrow_t&) noexcept {deallocate(p);}
