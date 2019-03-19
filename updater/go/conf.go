package main

import (
	"bytes"
	"fmt"
	"os"
	"regexp"
	"time"
)

type confWriter struct {
	file    string
	module  string
	mtime   string
	content []byte
}

func newConfWriter(file, module, mtime string) *confWriter {
	return &confWriter{
		file:   file,
		module: module,
		mtime:  mtime,
	}
}

func (cw *confWriter) write(params []moduleParam) error {
	var content bytes.Buffer
	for _, p := range params {
		content.WriteString(p.path)
		if p.json {
			content.WriteString(":JSON")
		}
		content.WriteString(" ")
		content.WriteString(p.value)
		content.WriteString("\n")
	}
	cw.content = content.Bytes()
	return nil
}

var contentRe = regexp.MustCompile(`(?m)^(?:\s*|#.*)(?:\n|$)`)

func (cw *confWriter) isModified(oldContent []byte) (bool, error) {
	return !bytes.Equal(contentRe.ReplaceAll(oldContent, []byte{}), cw.content), nil
}

func (cw *confWriter) close() error {
	f, err := os.Create(cw.file)
	if err != nil {
		return err
	}

	_, err = fmt.Fprintf(f, "# This file is autogenerated by %s at %s\n", os.Args[0], time.Now().Format("2006-01-02 15:04:05"))
	if err != nil {
		f.Close()
		return err
	}
	_, err = fmt.Fprintf(f, "#! Name %s\n", cw.module)
	if err != nil {
		f.Close()
		return err
	}
	_, err = fmt.Fprintf(f, "#! Version %s\n\n", cw.mtime)
	if err != nil {
		f.Close()
		return err
	}
	_, err = f.Write(cw.content)
	if err != nil {
		f.Close()
		return err
	}
	_, err = f.WriteString("#EOF")
	if err != nil {
		f.Close()
		return err
	}

	return f.Close()
}
