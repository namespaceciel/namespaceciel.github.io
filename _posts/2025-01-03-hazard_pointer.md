---
layout: post
title: C++26 hazard_pointer 的应用场景与实现浅析
header-img: img/table.JPG
header-style: text
catalog: true
tags:
  - C++
  - 无锁编程
  - 线程安全
  - 垃圾收集
---

![图片](/img/table.JPG)

C++26 引入了两种无锁的安全回收技术：`hazard_pointer` 和 `RCU`（read copy update），安全回收顾名思义是为了解决资源释放的问题，更具体一点其实是访问-删除竞争，即某个线程作为对象的所有者决定删除此对象时，还可能存在其它线程正在读取此对象，因而发生数据竞争。下面通过几个场景来说明这个问题。

## 1. 访问-删除竞争场景

### (1)

拿一个最简单的例子来说，假设我们有一个堆分配的 `Garbage` 对象对两个线程（以函数 `t1` `t2` 分别表示线程 1、2 的活动）均可见，线程 1 加载了 `ptr` 当前值以后，需要拿它做一些事，而与此同时线程 2 替换了 `ptr` 后删除了旧值，即线程 1 还在读取的 `p`，此时就发生了数据竞争。

```cpp
struct Garbage {
	int i;
};

std::atomic<Garbage*> ptr(new Garbage{1});

void t1() {
	Garbage* p = ptr.load();
	// do something with p...
}

void t2() {
	Garbage* old = ptr.exchange(new Garbage{2});
	delete old;
}
```

### (2)

之前的文章中曾经讲过无锁算法的一种普遍的设计思路：不同线程各自独立对数据结构的某一点进行修改，再在某一点通过 CAS、exchange 等操作原子性地更新使得其它线程可见，以此进行同步。这里通过一个多读者单写者的单链表来介绍相同的问题。

```cpp
// head -> [1] -> [2] -> [3] ...
```

这里的 `head` 是类中指向链表头的**原子**指针，而后面的 123 则都是动态分配内存的一个个结点。

此时我们作为唯一的写者线程，想修改结点 1 中的数据，我们肯定不能直接修改，不然就会与无数的读者线程产生数据竞争，所以我们需要创建一个新的结点 1'，复制结点 1 的数据给 1'，再独自修改 1‘ 的数据，然后让其指向结点 2。

```cpp
// head -> [1] -> [2] -> [3] ...
//              /
//         [1']
```

此时还不会发生任何问题，因为以上的操作还未对读者线程可见，读者们还是从结点 1 开始读取信息。

```cpp
// head    [1] -> [2] -> [3] ...
//       \      /
//         [1']
```

直到我们通过 `head.store(1')` 将链表头更新为 1' 后，新来的读者线程就开始通过 1' 读取新数据了，也没有任何问题。

之后问题来了，结点 1 什么时候才能被删除？因为它是堆内存所以不删除就会泄露，但是由于可能存在更新链表头之前就开始读取的读者线程现在还停留在结点 1 上，所以贸然删除就会发生数据竞争。

### (3)

最后一个例子是大名鼎鼎的 `std::shared_ptr` 是否线程安全的问题，答案是它只在一个情况下不安全，而那个场景跟第一个例子基本一致。

```cpp
std::shared_ptr<int> ptr(std::make_shared<int>(1));

void t1() {
	std::shared_ptr<int> p2 = ptr;
}

void t2() {
	ptr = std::make_shared<int>(2);
}
```

一开始 `ptr` 的引用计数为 1，然后线程 2 决定更新 `ptr` 为新指针，此时旧指针的引用计数就会变为 0，并且触发析构函数和堆内存释放。同时线程 1 尝试在旧指针析构时访问就会导致数据竞争。

有些人看到前两个例子的时候会想到用引用计数来解决这个问题，但是一般的引用计数技术是被一并存储在堆内存中，而读者在读取堆内存到增加引用计数之间的时刻依然会发生堆内存释放的问题。所以 `std::shared_ptr` 也因此无法做到线程安全。

## 2. `hazard_pointer` 简介

`hazard_pointer` 就是为了解决以上的问题，即让读者线程在不持有数据所有权的情况下安全访问直到结束，在这段时间内如果写者线程想要释放数据，这个操作会被推迟到读者访问结束后，并且保证不泄漏内存。

从一个宏观的角度来解释，`hazard_pointer` 其实类似一个全局的公告板，当读者想要读取时，就会把那个指针的地址写入公告板上，之后正常访问即可，而写者想要释放这块数据时，如果它看到公告板上存在这块数据，它就会用一个链表暂存它，这个链表中的数据之后还会经常被查看与尝试清理。有点类似于手动垃圾回收。

它的 API 相比上一节例子 1 也要稍作修改：

```cpp
struct Garbage : std::hazard_pointer_obj_base<Garbage> {
	int i;
};

std::atomic<Garbage*> ptr(new Garbage{1});

void t1() {
	std::hazard_pointer hp = std::make_hazard_pointer();

	Garbage* p = hp.protect(ptr);
	// do something with p...
	hp.reset_protection(); // 手动释放保护，可有可无
}

void t2() {
	Garbage* old = ptr.exchange(new Garbage{2});
	old->retire();
}
```

首先对于需要保护的类 `T` 来说，它需要继承自 `std::hazard_pointer_obj_base<T>` 来获得这样的能力，这里用了 CRTP 来让 `std::hazard_pointer_obj_base` 获得自己的信息。

之后当线程 1 想要读取 `ptr` 数据时，它需要调用 `std::make_hazard_pointer()` 拿到一个 `hazard_pointer hp`，之后通过调用 `hp.protect(ptr)` 来保护 `ptr` 目前存储的对象，并且返回这个对象的裸指针 `p`，之后通过 `p` 正常访问即可。

线程 2 这边，我们将 `delete old;` 替换为了 `old->retire();`，即“我这边已经不需要它了，但是请等到所有读者访问结束后再删除它”。

最后线程 1 结束访问时可以调用 `hp.reset_protection();` 释放保护，此时这根指针从用户侧看来就算是被释放了，但实际上它离实际被释放还会有一段延迟。这里即使不调用释放也没有关系，因为 `hazard_pointer` 底层是会被重用的，下次对着新原子指针调用 `protect` 的时候，旧保护就被释放了。一个 `hazard_pointer` 同一时刻只能保护一根指针。

## 3. `hazard_pointer` 简单实现细节

由于 `hazard_pointer` 目前还没有被三大编译器的库所实现，只有 [Folly](https://github.com/facebook/folly) 库有一份较为复杂的实现。并且它除了核心思想以外，实现细节上有很多地方都是很灵活的，所以目前只大概介绍一下一种简单的实现。

### (1) `hazard_slot`

每一个 `hazard_pointer` 的实现类我们称为 `hazard_slot`，它同一时刻只被一个线程所持有，但会被其它线程读取。

它内部需要有三个原子指针，`next` 是用来将所有 `hazard_slot` 串成一个单链表以便访问，`in_use` 是表示当前这个 slot 是否正被线程所持有，`protected_ptr` 就是它当前在保护的指针。

```cpp
struct hazard_slot {
	std::atomic<hazard_slot*> next{nullptr};
    std::atomic<bool> in_use;
    std::atomic<garbage_type*> protected_ptr{nullptr};
};
```

全局有一个单例的 `hazard_slot` 管理中心，我们称为 `hazard_slot_headquarter`，它存储着 `hazard_slot` 链表头，在构造函数中可以预分配足够多的 `hazard_slot`，尽量避免后续的内存申请，在析构函数中挨个释放它们。

而在 `get_slot` 和 `return_slot` 中，我们通过 `in_use` 的判断和修改来拿到一个空闲的 `hazard_slot`。如果不存在那就新分配一个挂在链表上。

```cpp
class hazard_slot_headquarter {
	hazard_slot* const hazard_slot_list_head;

    hazard_slot_headquarter()
        : hazard_slot_list_head(new hazard_slot{false}) {
        // std::thread::hardware_concurrency() may return 0.
        hazard_slot* cur = hazard_slot_list_head;
        for (unsigned int i = 1; i < std::thread::hardware_concurrency() * 2; ++i) {
            hazard_slot* next = new hazard_slot{false};
            cur->next.store(next, std::memory_order_relaxed);
            cur = next;
        }
    }

    ~hazard_slot_headquarter() {
        hazard_slot* cur = hazard_slot_list_head;
        while (cur) {
            hazard_slot* old = std::exchange(cur, cur->next.load(std::memory_order_relaxed));
            delete old;
        }
    }

    hazard_slot* get_slot() {
        hazard_slot* cur = hazard_slot_list_head;

        while (true) {
            if (!cur->in_use.load(std::memory_order_relaxed)
                && !cur->in_use.exchange(true, std::memory_order_relaxed)) {
                return cur;
            }

            hazard_slot* next = cur->next.load(std::memory_order_relaxed);
            if (next == nullptr) {
                hazard_slot* new_slot = new hazard_slot{true};

                while (!cur->next.compare_exchange_weak(next, new_slot, std::memory_order_relaxed)) {
                    cur  = next;
                    next = nullptr;
                }

                return new_slot;
            }

            cur = next;
        }
    }

    void return_slot(hazard_slot* slot) noexcept {
        slot->in_use.store(false, std::memory_order_relaxed);
    }
};
```

之后当我们调用 `make_hazard_pointer()` 时，只需从 `hazard_slot_headquarter` 中取出一个 slot。`protect` 与 `reset_protection` 即是设置 `protected_ptr` 的过程。

### (2) `protect`

`protect` 类似 CAS，可能需要尝试多次，每一次都需要比较设置 `protected_ptr` 前后 `src` 的内容，如果不相等那说明 `protected_ptr` 没来得及保护那个旧值，所以只能用新值重试。

```cpp
template<class T>
void reset_protection(const T* ptr) noexcept {
    slot_->protected_ptr.store(const_cast<T*>(ptr), std::memory_order_release);
}

void reset_protection(nullptr_t = nullptr) noexcept {
    slot_->protected_ptr.store(nullptr, std::memory_order_release);
}

template<class T>
bool try_protect(T*& ptr, const std::atomic<T*>& src) noexcept {
	T* p = ptr;
	reset_protection(p);

	ptr = src.load(std::memory_order_acquire);
	if (p != ptr) {
		reset_protection();
		return false;
	}

	return true;
}

template<class T>
T* protect(const std::atomic<T*>& src) noexcept {
	T* ptr = src.load(std::memory_order_relaxed);

	while (!try_protect(ptr, src)) {}

	return ptr;
}
```

### (3) `retire`

之前说到被风险保护的类需要继承自 `std::hazard_pointer_obj_base`，那只要我们在基类中加入链表结点，待回收对象们就可以轻松被串在一起。之后当它们累计到一定数量后，我们扫描一遍链表，同时我们也可以通过访问 `hazard_slot_headquarter` 的 slot 链表来得知所有正在被保护的指针。这样我们就可以清理掉不被保护的结点们。

需要注意的是对每个 `protected_ptr` 的访问都需要使用 `std::memory_order_acquire`，与 `protect` 过程中的 `std::memory_order_release` 形成释放-获取定序。

```cpp
hazard_slot* cur = hazard_slot_headquarter::get().hazard_slot_list_head;
while (cur) {
    auto p = cur->protected_ptr.load(std::memory_order_acquire);
    if (p) {
        // Record this pointer...
    }

    cur = cur->next.load(std::memory_order_relaxed);
}
```

待回收对象链表也要线程安全，简单的办法就是像 `hazard_slot` 一样被单线程持有，具体可能并没有一个最好的解法所以此处不细说。
