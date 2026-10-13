import ballerina/test;

@test:Config {}
function testValue() {
    int value = checkpanic int:fromString("1");
    test:assertEquals(value, 1);
}
