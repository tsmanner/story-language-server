# Story Language Server (sls)

This language server facilitates navigation through a set of Story files.  Story files are plain text, with extension
`.sty`.  It associates words in the current file with file names in the same directory tree, and presents related files
through the [go to definition][1] command and [documentation][2] completion item.

The directory tree is detected by searching for the nearest file named `.story` starting from the current directory and
searching through parents.

[1]: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#textDocument_definition
[2]: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#completionItem
