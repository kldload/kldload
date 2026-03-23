from socket_snoop import format_ip, connection_id  # type: ignore

def test_format_ip():
    assert format_ip(0x7F000001) == "127.0.0.1"
    assert format_ip(0xC0A80101) == "192.168.1.1"

def test_connection_id_stable():
    a = connection_id("10.0.0.1", 1234, "10.0.0.2", 80)
    b = connection_id("10.0.0.1", 1234, "10.0.0.2", 80)
    assert a == b
    assert len(a) == 32
