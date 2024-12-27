---
layout: post
title: C++ 以引用计数器的不同实现介绍一下无阻塞算法
header-img: img/tree2.JPG
header-style: text
catalog: true
tags:
  - C++
  - 多线程
  - 引用计数
  - 无锁编程
  - CAS
  - lock-free
  - wait-free
---

![图片](/img/tree2.JPG)

本文参考自 Daniel Anderson 的 CppCon 演讲 [https://www.youtube.com/watch?v=kPh8pod0-gk](https://www.youtube.com/watch?v=kPh8pod0-gk) 与 Michael Scott 的 SPTDC 演讲 [https://www.youtube.com/watch?v=9XAx279s7gs](https://www.youtube.com/watch?v=9XAx279s7gs)
{:.info}

## 1. 进度保证

多线程算法从执行进度上可以分为四类：阻塞、非阻塞、无锁 (lock-free) 和无等待 (wait-free)。其中阻塞和非阻塞互为补集，非阻塞是无锁的超集，无锁又是无等待的超集。无锁和无等待便是通常意义上的无锁编程。

但是这并不代表算法中没有锁就属于无锁编程，虽然 90% 的情况下它们是一致的，但是无锁编程确实有更准确的描述。

更需要注意的是，这个分类只是根据进度保证所得的结论。无锁算法并不代表着一定会比阻塞算法快，无等待算法也不一定会比无锁算法快，更不代表着其它任何保证。举例来说，无锁算法也可能会导致线程饥饿，而有一种锁叫做 `TicketLock`，它可以根据锁申请顺序来逐个给线程们执行权限，反而不会导致线程饥饿。

### (1) 阻塞算法

形如 `std::mutex` 或者自旋锁等，当一个线程拿到锁之后，其余所有试图拿锁的线程都会被卡在那个地方，无法做任何事情，这便是阻塞算法。如果设计不合理阻塞算法还可能导致死锁。

### (2) 非阻塞算法

非阻塞算法保证了如果在隔离状态下（即所有其它线程都暂停）给予某个线程足够的时间，它能够保证执行完。这其中隐含的一个跟阻塞算法的区别就是它绝对不会死锁。

### (3) 无锁算法

无锁算法保证了在全局范围下，每个时刻总有至少一个线程会做出有效进展。

无锁算法关联着一个非常有代表性的操作：CAS (compare and swap)，这个操作的调用形如 `current.compare_exchange_weak(T& expected, T desired)`，它会比较 `current` 与 `expected`，如果相等则以 `desired` 替换 `current`，否则则将 `current` 更新值加载至 `expected`。

它的语义在于，如果 `expected` 与 `current` 相等，则认为在这段时间中没有其它线程来修改过 `current`，所以就可以把自己的进度安全地发布出去；如果不相等那只能说明其它线程抢先了一步。

CAS 完美地解释了无锁算法的进度保证：在任何时刻都至少有一个线程会做出有效的进展，因为如果 CAS 成功了，那本线程则做出了有效进展；如果 CAS 失败了，则只会是有其它线程做出了有效进展而导致的后果。

CAS 同时也说明了无锁算法的一种普遍的设计思路：不同线程各自独立对数据结构的某一点进行修改，再在某一点通过 CAS、exchange 等操作原子性地更新使得其它线程可见（这一点也被称为可线性化点），以此进行同步。这次更新可能会失败，那么该线程只需回退操作重试即可。

但是 CAS 确实可能会让某个线程一直被其它线程的成功影响而导致失败并且最终饥饿。所以如果有的实时性系统需要让每个操作都在规定时间内完成，那无锁算法的保证是不够的。

### (4) 无等待算法

无等待算法保证了在全局范围下，所有线程都可以同时做出有效进展。

无等待算法的性能并不一定优于无锁算法。实际上上世纪就已经出现了一种通用的构造方法，可将任意一个无锁算法机械式地改成无等待算法，性能可能会也可能不会提升，而且还伴随着巨大的内存需求增长。

## 2. 线性一致性

如果一个系统的执行（例如调用函数与获取返回值等操作，它们会重叠发生）序列 H 的结果，等价于这些执行单独接连发生的某一种序列 S 的结果，并且序列 S 与所有线程的感知历史都能保持一致，那么这个结果是线性一致的。如果一个数据结构所产生的所有可能的结果都是线性一致的，那么这个数据结构是线性一致的。

在另一种定义下，序列 S 的每次执行似乎都等价于一个瞬间完成并被系统中并发运行的所有其它线程所感知的点，这些点被称为可线性化点。可线性化点可能是固定静态点，也可能是动态可知的点，例如 CAS 一般只有在成功时才会成为可线性化点。

线性一致性具有可组合性，即两个线性一致的系统的组合也是线性一致的，这个性质使得其在多线程算法正确性证明中显得非常方便。

## 3. 引用计数器的设计需求

在 `std::shared_ptr` 等通过引用计数而进行资源管理的数据结构中，引用计数器的实现很大程度上影响着数据结构总体性能及安全性。

从整体上而言，计数器需要满足三个条件：

(1) 从 1 开始计数，代表着初始情况下由它的创建者持有着唯一一个引用。

(2) 之后只要计数器降为 0，则管理的资源就会被释放，所以计数器绝对不能从 0 升回 1。

(3) 而在到达 0 之前，对计数器的递增递减操作数需要保持严格相等，因为只有之前递增而获取引用的才有权利递减而移除自己持有的那份引用。所以计数器绝对应该在最后到达 0 且绝不会递减到负数。

从实现上而言，计数器需要提供三个函数：

(1) `increment_if_not_zero` 仅在当前计数非 0 时才递增并返回 `true`，否则返回 `false`。

(2) `decrement` 递减计数，并只对唯一到 0 的那一次递减返回 `true`，这代表着那一次函数调用的发起者需要负责之后的资源释放。其它时候返回 `false`。

(3) `load` 返回当前的计数，如果它从某一刻返回了 0，之后不可能再返回非 0。

## 4. 引用计数器的不同实现

### (1) 简单的无锁算法实现

这个算法很简单所以就直接放完整代码：

```cpp
class Counter {
private:
	std::atomic<size_t> count_{1};

public:
	bool increment_if_not_zero(std::memory_order order = std::memory_order_seq_cst) noexcept {
		size_t cur = count_.load(std::memory_order_relaxed);

        do {
            if (cur == 0) {
                return false;
            }
        } while (count_.compare_exchange_weak(cur, cur + 1, order, std::memory_order_relaxed));

        return true;
	}

	bool decrement(std::memory_order order = std::memory_order_seq_cst) noexcept {
		return count_.fetch_sub(1, order) == 1;
	}

	size_t load(std::memory_order order = std::memory_order_seq_cst) const noexcept {
		return count_.load(order);
	}
};
```

递减和读取都是直接调用 `std::atomic` 的原子操作即可，只有递增有一个“仅在当前非 0”的前提，所以不能简单地调用 `fetch_add` 而要通过 CAS 在当前为 0 时直接返回 `false`。如果线程们的修改非常激烈的话，当前线程的 CAS 循环可能会失败很多次。

### (2) 巧妙的无等待算法实现

循环 CAS 的特点基本表示了有它的存在就告别无等待算法了，它跟无等待算法有一个本质的区别是 CAS 是一个线程竞争性质的操作，我们没有办法做到事先得知别的线程要修改所以我们乖乖排在它们后面紧接着修改的操作，唯一得知这件事的时候就是 CAS 失败时，而这同时也是线程竞争失败时，所以线程间绝对做不到互相提醒和帮助。正因如此，我们需要完全重构这个算法。

注意到这个问题的难点在于，多线程无法及时探测到计数器归零的事实，所以才需要循环 CAS 来时刻提防这个特例，如果我们在另外的地方保存一个 flag 来指示计数器已经归零，即使靠递增把那个数字从 0 拉回 1 也不影响其它线程靠 flag 得知已经归零的事实，那么循环 CAS 就可以被去除了。

为此，我们挑选了 `size_t` 的最高一位来当做这个 `zero_flag`，当这一位被置为 1 时，就代表着计数器已经归零。之后即使低位的那些数再被怎么递增，我们看到 `zero_flag` 就一律让 `increment_if_not_zero` 返回 `false`，`load` 也同理返回 0 即可。

```cpp
class Counter {
private:
	static constexpr size_t zero_flag = static_cast<size_t>(1) << (std::numeric_limits<size_t>::digits - 1);

	std::atomic<size_t> count_{1};
};
```

在这个基础下，我们先实现 `decrement` 和 `increment_if_not_zero` 的部分：

```cpp
bool decrement(std::memory_order order = std::memory_order_seq_cst) noexcept {
	if (count_.fetch_sub(1, order) == 1) {
		size_t temp = 0;
		return count_.compare_exchange_strong(temp, zero_flag, order, std::memory_order_relaxed);
	}
	return false;
}

bool increment_if_not_zero(std::memory_order order = std::memory_order_seq_cst) noexcept {
	return (count_.fetch_add(1, order) & zero_flag) == 0;
}
```

目前我们有这样的雏形，当我们当前递减到 0 时，我们通过 `compare_exchange_strong` 尝试设置 `zero_flag`，如果设置成功则返回 `true`。之后所有线程看到 `zero_flag` 都会达成共识。

如果设置失败，那么只能说明 `increment_if_not_zero` 的 `fetch_add` 抢先了一步，把当前的 0 重新拉回了 1。但是注意这不会导致计数器出现异常，因为 `increment_if_not_zero` 最终返回了 `true` 而 `decrement` 返回了 `false`。从可线性化点的角度来说，大家感知到的执行序列是先递增再递减，即 1 -> 2 -> 1，而不是内部实际发生的 1 -> 0 -> 1，而这个序列结果是完全合法的。所以这样的 `zero_flag` 设置可能会被尝试很多次，直到成功为止。

另外一个非常重要的点是，CAS 在 C++ 中有两种分别为 `compare_exchange_strong/weak`，其中 weak 版本允许出现虚假的失败。在 X86 架构上它们的实现是一样的，而在 ARM 架构上 weak 版本会更有效率。

但是在这个实现中，我们必须要用 strong 版本，这是因为唯一可导致 `decrement` 失败的原因只应该是 `fetch_add` 成功，如果这里实际上没有任何线程干扰而出现了虚假失败，那本次操作本应负责的资源释放就没人会做了（除非之后还有线程再来 0 -> 1 -> 0 并且没出现虚假失败）。

最后对于 `load` 有两种截然不同的处理思路。

简单的一种是，如果 `zero_flag` 被设置，那么返回 0；否则如果位全为 0，代表着有一次 `decrement` 正执行到一半，因为可能会失败所以我们直接将其视为还未调用，直接返回 1；其它情况下直接返回计数即可。

```cpp
size_t load(std::memory_order order = std::memory_order_seq_cst) const noexcept {
	size_t val = count_.load(order);
	if (val & zero_flag) {
		return 0;
	}
	return val != 0 ? val : 1;
}
```

那么到此为止这就有了一版完整的实现。

而复杂的一种是，既然我们得知了有一次 `decrement` 正执行到一半，而且在竞争中可能落败，我们能否贡献出自己的一份力，帮它设置 `zero_flag` 呢。在这种情况下我们的 `read` 则可以这么写：

```cpp
size_t load(std::memory_order order = std::memory_order_seq_cst) const noexcept {
	size_t val = count_.load(order);
	if (val == 0 && count_.compare_exchange_strong(val, zero_flag, order, std::memory_order_relaxed)) {
		return 0;
	}
	return (val & zero_flag) ? 0 : val;
}
```

但是这带来了一个新的问题，如果 `zero_flag` 最终是由 `load` 成功设置的，那么 `decrement` 那边返回的全为 `false`，就没有负责资源释放的了。所以在此基础上，我们何不妨再引入一个 `help_flag` 来提示 `decrement`。

```cpp
static constexpr size_t help_flag = static_cast<size_t>(1) << (std::numeric_limits<size_t>::digits - 2);

size_t load(std::memory_order order = std::memory_order_seq_cst) const noexcept {
	size_t val = count_.load(order);
	if (val == 0 && count_.compare_exchange_strong(val, zero_flag | help_flag, order, std::memory_order_relaxed)) {
		return 0;
	}
	return (val & zero_flag) ? 0 : val;
}
```

我们在 `load` 中同时设置了两个 flag。而在 `decrement` 那边则有新事件要处理，因为 CAS 此时多了一个失败的可能原因，是 `load` 的帮忙。所以我们再检测 `help_flag` 是否被设置了，如果被设置了，那么 `decrement` 们则需要有且仅有一个抢到释放资源权，这里通过 `exchange` 操作仅由一个线程置换出 `help_flag`，它就是负责后事的。

```cpp
bool decrement(std::memory_order order = std::memory_order_seq_cst) noexcept {
	if (count_.fetch_sub(1, order) == 1) {
		size_t temp = 0;
		if (count_.compare_exchange_strong(temp, zero_flag, order, std::memory_order_relaxed)) {
			return true;
		} else if ((temp & help_flag) && (count_.exchange(zero_flag) & help_flag)) {
			return true;
		}
	}
	return false;
}
```

由此得到另一版完整实现如下：

```cpp
class Counter {
private:
	static constexpr size_t zero_flag = static_cast<size_t>(1) << (std::numeric_limits<size_t>::digits - 1);
	static constexpr size_t help_flag = static_cast<size_t>(1) << (std::numeric_limits<size_t>::digits - 2);

	std::atomic<size_t> count_{1};

public:
	bool increment_if_not_zero(std::memory_order order = std::memory_order_seq_cst) noexcept {
		return (count_.fetch_add(1, order) & zero_flag) == 0;
	}

	bool decrement(std::memory_order order = std::memory_order_seq_cst) noexcept {
		if (count_.fetch_sub(1, order) == 1) {
			size_t temp = 0;
			if (count_.compare_exchange_strong(temp, zero_flag, order, std::memory_order_relaxed)) {
				return true;
			} else if ((temp & help_flag) && (count_.exchange(zero_flag) & help_flag)) {
				return true;
			}
		}
		return false;
	}

	size_t load(std::memory_order order = std::memory_order_seq_cst) const noexcept {
		size_t val = count_.load(order);
		if (val == 0 && count_.compare_exchange_strong(val, zero_flag | help_flag, order, std::memory_order_relaxed)) {
			return 0;
		}
		return (val & zero_flag) ? 0 : val;
	}
};
```
