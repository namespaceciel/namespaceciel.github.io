---
layout: post
title: C++ 为什么各大标准库的 std::vector::iterator 不直接用 T*？
header-img: img/cat.png
header-style: text
catalog: true
tags:
  - C++
---

![图片](/img/cat.png)

本文参考自 Arthur O'Dwyer 的博客：[https://quuxplusone.github.io/blog/2022/03/03/why-isnt-vector-iterator-just-t-star/](https://quuxplusone.github.io/blog/2022/03/03/why-isnt-vector-iterator-just-t-star/)
{:.info}

## 0. 现状

C++ 的很多容器，例如 `std::vector`、`std::string`、`std::span`、`std::string_view` 等，它们的迭代器都可以直接用 `T*`，但是这些标准库基本都有自己的包装迭代器，详见下表：

| Type   | GNU libstdc++    | LLVM libc++  | MSVC STL |
|--------|--------------|---------|------|
| `initializer_list<T>::iterator` | `const T*` | `const T*` | `const T*` |
| `array<T, N>::iterator`          | `T*` | `T*` | `std::_Array_iterator<int,10>` |
| `span<T>::iterator`               | `__gnu_cxx::__normal_iterator<int*, std::span<int>>` | `std::__wrap_iter<int*>` | `std::_Span_iterator<int>` |
| `string::iterator`                | `__gnu_cxx::__normal_iterator<char*, std::string>` | `std::__wrap_iter<char*>` | `std::_String_iterator<std::_String_val<std::_Simple_types<char>>>` |
| `string_view::iterator`           | `const char*` | `const char*` | `std::_String_view_iterator<std::char_traits<char>>` |
| `vector<T>::iterator`             | `__gnu_cxx::__normal_iterator<T*, std::vector<T>>` | `std::__wrap_iter<T*>` | `std::_Vector_iterator<std::_Vector_val<std::_Simple_types<T>>>` |

这些包装类基本都是存一个指针在内部，然后重载各种运算符，使得其表现的跟裸指针基本一致。

在 debug 模式下，也可以多存 `begin` 和 `end` 指针等，使得其在各种操作前都可以检查有没有越界等。

这些对指针的包装行为会让程序不可避免地变得笨重。如果没有特别需求的话，自己实现的容器用指针确实就可以了。但是它们确实有其存在的很多作用。

## 1. 避免从 `T*` 的隐式转换

作为一个足够健壮的库，一个容器的迭代器应该表现得像一个独立类型，但是如果直接用 `T*` 作为迭代器，它就无法跟其它指针操作区分开。

```cpp
void f(std::vector<int>::iterator);

f(nullptr);
```

`nullptr` 可以隐式转换成 `int*` 指针，但是一个接受 `std::vector<int>` 迭代器的函数真的应该接受 `nullptr` 而不报错吗。这是非常不合理的。

## 2. 避免不同容器迭代器的转换

同上，一个容器的迭代器应该表现得像一个独立类型。`std::vector<char>` 和 `std::string` 的迭代器自然不应该是同一类型。但是不管是用 `char*` 还是 libc++ 的 `std::__wrap_iter<char*>` 都避免不了这个问题。

MSVC STL 直接为每个容器各写了一套迭代器，简单粗暴但是可能没什么必要。

libstdc++ 只是多加了一个模板参数作为标签，就足够区分类型和避免转换了。

## 3. 避免派生类指针到基类指针的转换

```cpp
struct Base {};
struct Derived : Base {};

void f(std::vector<Base>::iterator);

int main() {
    std::vector<Derived> v;
    f(v.begin());
}
```

还是同上，如果迭代器是 `T*` 那么上述代码就可以通过编译，但显然不应该让它通过。

但是 libc++ 的 `std::__wrap_iter` 没有防止这个问题，甚至是特意检查了指针能转换就放行。

```cpp
template <class _Up, __enable_if_t<is_convertible<_Up, iterator_type>::value, int> = 0>
_LIBCPP_HIDE_FROM_ABI _LIBCPP_CONSTEXPR_SINCE_CXX14 __wrap_iter(const __wrap_iter<_Up>& __u) _NOEXCEPT
    : __i_(__u.base()) {}
```

## 4. ADL

这节需要插入一点点前置知识。

实参依赖查找（ADL），又称 Koenig 查找，是一组对函数调用表达式（包括对重载运算符的隐式函数调用）中的无限定的函数名进行查找的规则。在通常无限定名字查找所考虑的作用域和命名空间之外，还会在它的各个实参的命名空间中查找这些函数。

这里只说它最简单的用法，标准库有一个 `std::swap` 函数，但是对于很多类型，用户可能有自定义的效率更高的 `swap` 函数。那么在泛型情况下，我们能不能不用一些麻烦的判断，而是在一套操作中对所有类型自动转发：如果类型有其自定义 `swap` 函数，就调用它，没有就 fallback 到 `std::swap` 上呢。这就可以用到 ADL。

```cpp
#include <utility> // std::swap

namespace my {

struct T {};
void swap(T&, T&);

} // namespace my

int main() {
    my::T t1, t2;
    using std::swap;
    // callq my::swap(my::T&, my::T&)@PLT
    swap(t1, t2);
}
```

上例中我们在自己的 `my` 名字空间中定义了 `T` 的专属 `swap` 函数，而我们之后调用 `swap(t1, t2)` 却不用加 `my::`，因为 `t1` 和 `t2` 都是 `my` 里的成员，编译器会自动把 `my` 里的所有函数也带出来。再加上前面 `using std::swap`，就存在两个 `swap` 函数进行重载决议，而自己定义的版本更加特殊，所以会选择它。

进入正题：

```cpp
#include <algorithm> // std::iter_swap

namespace std {

template<class Pointer>
struct Iter {
    std::remove_pointer_t<Pointer>& operator*() const noexcept { static std::remove_pointer_t<Pointer> res; return res; }

    struct type {
        std::remove_pointer_t<Pointer>& operator*() const noexcept { static std::remove_pointer_t<Pointer> res; return res; }
    }; // struct type

}; // struct Iter

template<class T>
struct Container1 { using iterator = T*; };
template<class T>
struct Container2 { using iterator = Iter<T*>; };
template<class T>
struct Container3 { using iterator = typename Iter<T*>::type; };

} // namespace std

struct A {
    friend void iter_swap(std::Container1<A>::iterator, std::Container1<A>::iterator);
    friend void iter_swap(std::Container2<A>::iterator, std::Container2<A>::iterator);
    friend void iter_swap(std::Container3<A>::iterator, std::Container3<A>::iterator);
}; // struct A

int main() {
    std::Container1<A>::iterator i1;
    // callq iter_swap(A*, A*)@PLT
    iter_swap(i1, i1);

    std::Container2<A>::iterator i2;
    // callq iter_swap(std::Iter<A*>, std::Iter<A*>)@PLT
    iter_swap(i2, i2);

    std::Container3<A>::iterator i3;
    // callq void std::iter_swap<std::Iter<A*>::type, std::Iter<A*>::type>(std::Iter<A*>::type, std::Iter<A*>::type)
    iter_swap(i3, i3);
}
```

我们假设了三个场景：迭代器分别为 `T*`、`std::Iter<T*>` 和 `typename std::Iter<T*>::type`。

在 algorithm 头文件中有一个 `std::iter_swap` 函数，`A` 为三种迭代器类型也都自定义了 `iter_swap` 函数。

对于 `T*` 而言，它不是 `std` 空间成员，所以根本不会去找 `std::iter_swap`，只有一个 `A` 的版本能用。

对于 `std::Iter<T*>` 而言，它既能找到 `std::iter_swap` 也能找到 `A` 的版本。但是 `A` 版本更特殊，最后选择了 `A` 版本。

对于 `typename std::Iter<T*>::type` 而言，它已经看不到 `A` 了！只能选择 `std::iter_swap`。

## 5. 内建类型的前置递增等操作只接受左值

```cpp
struct Iterator {
    int* i;
    Iterator& operator++() noexcept { ++i; return *this; }
};

Iterator f1();
int* f2();

int main() {
    ++f1();
    // ++f2(); // error: lvalue required as increment operand
}
```

这可能是本篇里最贴近大众的地方，因为很多人可能会写这样的代码 `auto& back = *(--v.end());`，它理所应当能通过编译，但是用指针就做不到了。
