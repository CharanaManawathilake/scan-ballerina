import ballerina/test;

@test:Config {}
function testMain() {
    int x = checkpanic int:fromString("1");
    test:assertEquals(x, 1);
}
