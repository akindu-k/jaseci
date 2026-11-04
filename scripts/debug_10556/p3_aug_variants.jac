def local_annot -> float {
    g: float = 10.0;
    g /= 2;
    return g;
}

def local_plain -> float {
    a = 9.0;
    a /= 2.0;
    return a;
}

with entry {
    g: float = 10.0;
    g /= 2;
    print("glob annot float /= int:", g);
    a = 9.0;
    a /= 2.0;
    print("glob plain float /= float:", a);
    b: float = 9.0;
    b /= 2.0;
    print("glob annot float /= float:", b);
    m: float = 10.0;
    m *= 2;
    print("glob *=:", m);
    s: float = 10.0;
    s -= 2;
    print("glob -=:", s);
    r: float = 10.0;
    r %= 4;
    print("glob %=:", r);
    f: float = 10.0;
    f //= 4;
    print("glob //=:", f);
    i = 7;
    i /= 2;
    print("glob int /= int:", i);
    print("local annot:", local_annot());
    print("local plain:", local_plain());
}
