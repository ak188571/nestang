# Tang Console 138K: NESのUSB Host回復

基板表示「32001C」のNES用NESTang。P1/P2にUSB Host自動回復を適用する。最初のHID report後、`START`待ちが100 ms続くか`conerr`が立ったとき、Host全体を約5 ms resetする。新しいreportが届くまで自動resetを繰り返さない。S1（USER_BUTTON0、AA13）を押している間は両Hostを手動resetし、PMODの8個のLEDを全点灯する。

ゲーム中のPMOD LED0〜7は順に、P1の新button（約0.5秒）、P1 `connected`、P1の直近report（約0.5秒）、P1 `START`待ちによる自動reset履歴、P1 `conerr`による自動reset履歴、現在のP1 `conerr`、Bitstream識別用の常時点灯、約1秒周期の点滅。P2の内部履歴は表示しない。

VID:PID `0079:0006`でNESゲーム中のP1を約25回挿抜し、毎回操作できた。LED3・4の両方に自動reset履歴が残った。S1を押している間の全LED点灯も確認した。

Gowin V1.9.12.03、`GW5AST-LV138PG484AC1/I0` version B、`gw_sh build.tcl console138k ds2`。設計全体のLogic 11,449/138,240、Register 6,480/139,095。報告されたsetup/hold違反は0/0だがclock間の警告が残る。採択した`cores/console138k/nestang.bin`は4,577,172 byte、SHA-256 `FDD2F04474748FC9F15F7FD808014C169608B0766C48BA80E4B20D5C59B3F8E6`。元版と実機試験の詳細は作業領域の総合報告に記録した。ゲームROMとBL616 Flashは変更しない。
