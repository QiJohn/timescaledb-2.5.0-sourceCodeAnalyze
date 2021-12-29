===========================================================配置================================================================
vscode中setting.json配置
{
	"workbench.editor.untitled.hint": "hidden",
	"cmake.configureOnOpen": true,
	"C_Cpp.vcFormat.indent.accessSpecifiers": true,
	"C_Cpp.vcFormat.indent.caseContentsWhenBlock": true,
	"C_Cpp.vcFormat.indent.caseLabels": true,
	"C_Cpp.vcFormat.indent.braces": true,
	"files.autoGuessEncoding": true,
	"editor.minimap.maxColumn": 40,
	"editor.wordSeparators": "\"`~!@#$%^&*()-=+[{]}\\\\|;:'\\\",.<>/?·～！￥…（）—【】、；：‘’“”，。《》？ \",",
	"window.title": "${dirty}${activeEditorLong}${separator}${rootName}${separator}${appName}",
	"workbench.sideBar.location": "right",
	"files.trimTrailingWhitespace": true,
	"tabnine.experimentalAutoImports": true,
	"editor.fontFamily": "'Source Code Pro', Consolas, 'Courier New', monospace\",Consolas, ",
	"workbench.iconTheme": "material-icon-theme",
	"workbench.colorTheme": "Default Light+",
	"editor.suggestSelection": "first",
	"vsintellicode.modify.editor.suggestSelection": "automaticallyOverrodeDefaultValue",
	"editor.detectIndentation": false,
	"editor.formatOnSave": true,
	"editor.insertSpaces": false,
	"bracket-pair-colorizer-2.depreciation-notice": false,
	"remote.SSH.remotePlatform": {
		"192.168.59.130": "linux"
	},
	"terminal.integrated.cursorStyle": "line",
	"terminal.integrated.cursorWidth": 0,
	"terminal.integrated.customGlyphs": false,
	"remote.SSH.showLoginTerminal": true,
	"launch": {
		"configurations": [
			{
				"name": "gdb Remote Launch",
				"type": "cppdbg",
				"request": "launch",
				"program": "/home/zq/software/postgresql-12.6/bin/postgres",
				"args": [
					"-D",
					"/home/zq/pgdata"
				],
				"stopAtEntry": false,
				"environment": [],
				"externalConsole": true,
				"MIMode": "gdb",
				"miDebuggerPath": "gdb",
				"miDebuggerArgs": "gdb",
				"linux": {
					"MIMode": "gdb",
					"miDebuggerPath": "/usr/bin/gdb",
					"miDebuggerServerAddress": "192.168.59.130:9555",
				},
				"logging": {
					"moduleLoad": false,
					"engineLogging": false,
					"trace": true
				},
				"setupCommands": [
					{
						"description": "Enable pretty-printing for gdb",
						"text": "-enable-pretty-printing",
						"ignoreFailures": false
					}
				],
				"cwd": "/home/zq",
			}
		]
	},
	"git.ignoreLegacyWarning": true,
}



vscode安装的插件有：
  本地主机插件：Remote-SSH
  远端主机插件：c/c++、Native Debug
 
 ==================================================实际操作流程===========================================================
远端主机： 
  开启PG数据库：pg_ctl start -D $PGDATA
  开启psql连接：psql -d postgres -U zq -p 5432
  获取psql连接的进程号
  开启gdbserver：gdbserver localhost:9555   --attach [psql进程号]


本地主机：
  vscode调试开启
