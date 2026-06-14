#[test_only]
module poseidon_parity::parity {
    use sui::poseidon::poseidon_bn254;
    const POSEIDON_1_2: u256 =
        0x115cc0f5e7d690413df64c6b9662e9cf2a3617f2743245519e19607a4417189a;
    const POSEIDON_1_2_3: u256 =
        0x0e7732d89e6939c0ff03d5e58dab6302f3230e269dc5b968f725df34ab36d732;
    const ZERO_16: u256 =
        0x2a7c7c9b6ce5880b9f6f228d72bf6a575a526f29c66ecceef8b753d38bba7323;
    #[test]
    fun poseidon_pair_matches_circomlib() {
        let out = poseidon_bn254(&vector[1u256, 2u256]);
        assert!(out == POSEIDON_1_2, 1);
    }
    #[test]
    fun poseidon_triple_matches_circomlib() {
        let out = poseidon_bn254(&vector[1u256, 2u256, 3u256]);
        assert!(out == POSEIDON_1_2_3, 2);
    }
    #[test]
    fun zero_ladder_root_matches() {
        let mut z: u256 = 0u256;
        let mut i = 0;
        while (i < 16) {
            z = poseidon_bn254(&vector[z, z]);
            i = i + 1;
        };
        assert!(z == ZERO_16, 3);
    }
}
