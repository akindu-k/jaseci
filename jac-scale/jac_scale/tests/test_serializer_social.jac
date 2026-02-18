"""Test serialization of social graph nodes."""
import from jaclang.runtimelib.serializer { Serializer }
import from jac_scale.tests.fixtures.social_graph { User, Post }

test "serialize user node" {
    # Create a user node
    u = User(name="Alice", role="admin", age=30);
    
    # Serialize
    serialized = Serializer.serialize(u, include_type=True);
    
    # Deserialize
    deserialized = Serializer.deserialize(serialized);
    
    # Verify
    assert deserialized.name == "Alice";
    assert deserialized.role == "admin";
    assert deserialized.age == 30;
    assert type(deserialized) == User;
}

test "serialize post node" {
    # Create a post node
    p = Post(title="Hello", content="World");
    
    # Serialize
    serialized = Serializer.serialize(p, include_type=True);
    
    # Deserialize
    deserialized = Serializer.deserialize(serialized);
    
    # Verify
    assert deserialized.title == "Hello";
    assert deserialized.content == "World";
    assert type(deserialized) == Post;
}
