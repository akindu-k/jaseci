def falsy -> bool {
    return bool(0);
}

with entry {
    print(bool(0), bool(2.5));
    print(bool(1));
    print(bool(""), bool("x"));
    print(not 0);
    print(1 > 2);
    print(True, False);
    print(str(bool(0)));
    print(f"{bool(0)}");
    print(falsy());
    x = bool(0);
    print(x);
}
