---
layout: post
title: C++ std::initializer_list 设计缺陷与[不正规]补救措施
header-img: img/fruit.png
header-style: text
catalog: true
tags:
  - C++
  - 模板元编程
---

![图片](/img/fruit.png)

本文前置知识见 [C++ SFINAE 简单介绍与两个常用用法](https://namespaceciel.github.io/2024/09/04/SFINAE/)
{:.info}

## 1. 重点介绍

`std::initializer_list<T>` 是 C++11 起对 `T` 类型只读数组的轻量代理对象，它的实现依赖于编译器。

它的用途主要是为容器提供初始化器列表的构造函数，例如 `std::vector` 的构造函数：

```cpp
vector(std::initializer_list<T> init, const Allocator& alloc = Allocator());
```

### (1) 花括号劫持

但它也有非常臭名昭著的点，比如会劫持花括号，即

```cpp
// 指 vector(size_type count, const T& value, const Allocator& alloc = Allocator());
// 构造 2 个值为 3 的 int 值
std::vector<int> v1(2, 3);
// 指 vector(std::initializer_list<T> init, const Allocator& alloc = Allocator());
// 构造两个值分别为 2 和 3 的 int 值
std::vector<int> v2{2, 3};
```

### (2) 构造条件

参见 [std::initializer_list - cppreference.com](https://zh.cppreference.com/w/cpp/utility/initializer_list)，`std::initializer_list` 在这些时候自动构造：

    用花括号包围的初始化式列表来列表初始化一个对象，其中对应的构造函数接受一个 std::initializer_list 形参。
    以花括号包围的初始化式列表为赋值的右操作数，或函数调用实参，且对应的赋值运算符/函数接受 std::initializer_list 形参。
    将花括号包围的初始化式列表绑定到 auto，包括在范围 for 循环中。

而 `{1, 2}` 本身并不是一个表达式，更不是 `std::initializer_list` 类型，实际上它压根不存在类型，它只是能从 `std::initializer_list` 的构造规则中转化成它。

这导致了如果定义一个模板函数，例如

```cpp
template<class T>
void f(T) {}

// f({1, 2}); // error
```

它是无法推导出 `T` 的，因为 `{1, 2}` 并没有类型。

**所以这里其实就已经产生了第一个小缺陷**，请看下面两个例子的对比：

```cpp
std::vector<int> v1{1, 2};

std::vector<std::vector<int>> v2;
// v2.emplace_back({1, 2}); // error
v2.push_back({1, 2});
```

因为上面介绍过 `std::vector` 有对应的构造函数，所以 `v1` 没有问题，而 `v2.push_back` 因为接受的参数是 `std::vector<int>`，所以也如 `v1` 一样构造了一个临时变量再移动构造进去，所以也没问题。

而 `v2.emplace_back` 则因为形参为变长模板，无法对 `{1, 2}` 推导类型，编译失败。

C++ 标准可能也意识到了这个问题，因为据我所知从 C++17 开始有很多类，比如 `std::variant` `std::expected` 等，构造函数都会在变长模板的基础上加上这样一个形式：

```cpp
// std::in_place_type_t 是一个占位符，提示要转到原地构造的构造函数上

template<class T, class... Args>
constexpr explicit variant(std::in_place_type_t<T>, Args&&... args);

template<class T, class U, class... Args>
constexpr explicit variant(std::in_place_type_t<T>, std::initializer_list<U> il, Args&&... args); // 专门为了 {...} 的正确转换
```

所以说 `std::vector::emplace_back` 这类函数其实也可以加上这样的重载版本。

### (3) const 元素

`std::initializer_list<T>` 的元素全为 `const T`，这导致了我们只能从里面复制构造每个元素，**这是公认的设计缺陷**，以下则是对这一缺陷的补救。

## 2. \[不正规]补救措施

拿我自己实现的 `vector` 举例，首先放上最终成果，我们一步步解释：

```cpp
template<class InitializerList,
         typename std::enable_if<std::is_same<InitializerList, std::initializer_list<T>>::value, int>::type
         = 0>
vector(InitializerList init, const allocator_type& alloc = allocator_type())
    : vector(init.begin(), init.end(), alloc) {}

template<class U = T,
         typename std::enable_if<worth_move<U>::value, int>::type
         = 0>
vector(std::initializer_list<move_proxy<T>> init, const allocator_type& alloc = allocator_type())
    : vector(init.begin(), init.end(), alloc) {}

template<class U = T,
         typename std::enable_if<!worth_move<U>::value, int>::type
         = 0>
vector(std::initializer_list<T> init, const allocator_type& alloc = allocator_type())
    : vector(init.begin(), init.end(), alloc) {}
```

### (1) 移动代理类

注意到这里的 `std::initializer_list<move_proxy<T>>`，`move_proxy` 是一个简单的代理类，它的实现如下：

```cpp
template<class T>
class move_proxy {
public:
    template<class... Args,
             typename std::enable_if<std::is_constructible<T, Args&&...>::value, int>::type
             = 0>
    move_proxy(Args&&... args) noexcept(std::is_nothrow_constructible<T, Args&&...>::value)
        : data_(std::forward<Args>(args)...) {}

    operator T&&() const noexcept {
        return std::move(data_);
    }

private:
    mutable T data_;

}; // class move_proxy
```

它会用万能引用原地构造一个 `mutable T data_` 成员变量，这使得它后续作为 `const move_proxy<T>` 也能被作为移动构造的参数。

`operator T&&() const noexcept` 则是可以隐式转换为 `T&&`，所以当我们

```cpp
move_proxy<T> mp;
T t{mp};
t = mp;
```

就分别调用了 `T` 的移动构造和移动赋值。

### (2) 只移动值得移动的 T

但是 `move_proxy` 也有自己的性能损失，所以我们可能希望只有需要移动的 `T` 才用 `move_proxy` 包一层。像基本类型例如 `int` `float` 等，以及它们的聚合体，并没有有意义的移动构造函数，直接复制就可。所以我最后总结的分界线就是，当 `T` 是类，且不为可平凡复制类，且可移动构造，且有用户（可能隐式）定义的移动构造函数。

“且有用户（可能隐式）定义的移动构造函数”与“可移动构造”并不是相同的定义，因为只要一个类定义了复制构造，右值引用也可以传给复制构造，`std::is_move_constructible` 也是同样的道理，即使 `T` 只定义了复制构造 `std::is_move_constructible<T>::value` 也为 `true`。

这里有一个不太完善的黑科技来检测 `T` 是否同时存在复制构造和移动构造函数，而不是只存在复制构造函数而导致 `std::is_move_constructible<T>::value` 为 `true`：

```cpp
// FIXME: Current implementation returns true for const&& constructor and assignment.
template<class T>
struct worth_move {
    static_assert(!std::is_const<T>::value);

private:
    using U = typename std::decay<T>::type;

    struct helper {
        operator const U&() noexcept;
        operator U&&() noexcept;
    }; // struct helper

public:
    static constexpr bool value = std::is_class<T>::value 
                               && !std::is_trivially_copyable<T>::value
                               && std::is_move_constructible<T>::value
                               && !std::is_constructible<T, helper>::value;

}; // struct worth_move
```

重点在于这个 `helper`，它可以同时转换为 `const U&` 与 `U&&` 两种类型，也就意味着它可以被复制构造和移动构造函数所接受，但是！不能同时被它们接受！因为这导致了函数调用选择二义性问题。所以如果 `T` 同时存在两个构造函数，`T` 就无法从 `helper` 的实例构造，所以 `std::is_constructible<T, helper>::value` 就为 `false`。

但是会不会一个类两种构造函数都不存在，而导致 `std::is_constructible<T, helper>::value` 假 `false` 呢，其实是不会的，因为就算显式 `delete` 了构造函数，构造函数也是一个定义过的函数，不存在一个类不定义构造函数的可能。

所以最后我们用 SFINAE 来将 `worth_move` 的两个结果分别写了模板重载。

而这个 `worth_move` 实现不太完善指的是类还可以有一个非常特殊的构造函数 `T(const T&&)`，虽然我不知道它的存在意义是什么，但是 `worth_move` 的逻辑无法区分它的存在，也没有任何解决办法。

### (3) 向 `std::vector` 等容器行为兼容

最后解释一下最终代码里的第一个构造函数模板重载，它的存在只是因为我们需要允许这样的用法：

```cpp
std::initializer_list<WorthMoveObject> il{};
std::vector<WorthMoveObject> v(il);
```

这是完全合法的，但是由于上面一通操作，`WorthMoveObject` 符合 `worth_move`，构造函数只存在一个接受 `std::initializer_list<move_proxy<T>>` 的版本，`il` 无法转换为这个类型。

所以我们定义了 `template<class InitializerList>`，并且用 SFINAE 确定了 `InitializerList` 推导出的结果只能为 `std::initializer_list<T>`，作为一个 backup 函数。因为 `il` 的类型已经是 `std::initializer_list<WorthMoveObject>` 类型了，不存在模板推导不出的问题。而由于它与另两个模板的特化程度不同，所以就算同时存在也不会有函数调用二义性问题。
