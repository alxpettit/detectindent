" Name:          detectindent (global plugin)
" Version:       1.? (no explicit versions)
" Author:        Ciaran McCreesh <ciaran.mccreesh at googlemail.com>,
"                Rory O’Kane <rory@roryokane.com>, and others
" Updates:       http://github.com/roryokane/detectindent
" Purpose:       Detect file indent settings
"
" License:       You may redistribute this plugin under the same terms as Vim
"                itself.
"
" Usage:         :DetectIndent
"
"                " to set a preferred indent level when detection is
"                " impossible:
"                :let g:detectindent_preferred_indent = 4
"
"                " see doc/detectindent.txt for more options
"
" Requirements:  Minimum Vim version is at least 7.0, because the code uses
"                dictionaries and +=

" Bail out if we're on an incompatible version of vim
if version < 700
    finish
endif

if exists("loaded_detectindent")
    finish
endif
let loaded_detectindent = 1

if !exists("g:detectindent_verbosity")
    let g:detectindent_verbosity = 1
endif

fun! <SID>HasCStyleComments()
    let l:c_style_comment_filetypes = ["arduino", "c", "cpp", "h", "java", "javascript", "php"]
    return index(l:c_style_comment_filetypes, &filetype) != -1
endfun

fun! <SID>HasHTMLStyleComments()
    let l:html_style_comment_filetypes = ["html", "xml"]
    return index(l:html_style_comment_filetypes, &filetype) != -1
endfun

fun! <SID>IsStartOfUnreliableComment(line)
    return (<SID>HasCStyleComments() && a:line =~ '/\*') || (<SID>HasHTMLStyleComments() && a:line =~ '<!--')
endfun

fun! <SID>IsEndOfUnreliableComment(line)
    return (<SID>HasCStyleComments() && a:line =~ '\*/') || (<SID>HasHTMLStyleComments() && a:line =~ '-->')
endfun

fun! <SID>IsUnreliableLineComment(line)
    return <SID>HasCStyleComments() && a:line =~ '^\s\+//'
endfun

fun! <SID>ContainsOnlyWhitespace(text)
    return a:text !~ '\S'
endfun

fun! <SID>GCD(a, b)
    let l:a = a:a
    let l:b = a:b
    while l:b > 0
        let l:temp = l:b
        let l:b = l:a % l:b
        let l:a = l:temp
    endwhile
    return l:a
endfun

fun! <SID>GCDOfMany(numbers_list)
    let l:gcd = 0
    for item in a:numbers_list
        if l:gcd == 0
            let l:gcd = item
        else
            let l:gcd = <SID>GCD(item, l:gcd)
        endif
    endfor
    return l:gcd
endfun

fun! <SID>SetLocalIndentWidth(num_spaces)
    let &l:tabstop = a:num_spaces

    " For 'softtabstop', use the value -1 to automatically sync with
    " 'shiftwidth', for convenience if the user manually changes 'shiftwidth'.
    try
        let &l:softtabstop = -1
    catch /^Vim\%((\a\+)\)\=:E487/ " the value -1 was not supported before Vim 7.4
        let &l:softtabstop = a:num_spaces
    endtry

    " 'shiftwidth' supports using the value 0 to sync with 'tabstop', which
    " would be convenient if the user manually changes 'tabstop'. But I don't
    " use that value here, because it breaks indenting in many languages.
    " This is because many language-specific indenting plugins, including ones
    " bundled with Vim, have not yet upgraded to use shiftwidth() instead of
    " 'shiftwidth'.
    let &l:shiftwidth = a:num_spaces
endfun

" use default setting in option or current setting
fun! <SID>SetDefaultLocalIndentWidth()
    if exists("g:detectindent_preferred_indent")
        call <SID>SetLocalIndentWidth(g:detectindent_preferred_indent)
    else
        " do nothing; keep the existing values of the options set by
        " SetLocalIndentWidth()
    endif
endfun

fun! <SID>RestrictIndentWidthWithinOptionRange(current_indent_width)
    let l:new_indent_width = a:current_indent_width
    if exists("g:detectindent_min_indent")
        let l:new_indent_width = max([g:detectindent_min_indent, l:new_indent_width])
    endif
    if exists("g:detectindent_max_indent")
        let l:new_indent_width = min([g:detectindent_max_indent, l:new_indent_width])
    endif

    if l:new_indent_width != a:current_indent_width
        call <SID>SetLocalIndentWidth(l:new_indent_width)
    endif
endfun

fun! <SID>DetectIndent()
    let l:leading_tab_count   = 0
    let l:leading_space_count = 0
    let l:leading_space_dict  = {}
    let l:leading_spaces_gcd  = 0
    let l:max_lines           = 1024
    if exists("g:detectindent_max_lines_to_analyse")
        let l:max_lines = g:detectindent_max_lines_to_analyse
    endif

    let verbose_msg = ''
    if !exists("b:detectindent_original_buffer_settings")
        " remember initial values for comparison
        let b:detectindent_original_buffer_settings =
            \ {'expandtab': &et, 'shiftwidth': &sw, 'tabstop': &ts, 'softtabstop': &sts}
    endif

    let l:idx_end = line("$")
    let l:idx = 1
    while l:idx <= l:idx_end && l:idx <= l:max_lines
        let l:line = getline(l:idx)

        " Skip past comment blocks and comment lines if we suspect that they
        " might be unusually indented and thus would give really screwy indent
        " settings.
        if <SID>IsStartOfUnreliableComment(l:line)
            while l:idx <= l:idx_end && !<SID>IsEndOfUnreliableComment(l:line)
                let l:idx += 1
                let l:line = getline(l:idx)
            endwhile
            let l:idx += 1
            continue
        endif
        if <SID>IsUnreliableLineComment(l:line)
            let l:idx += 1
            continue
        endif

        " Skip lines that are solely whitespace, since they're less likely to
        " be properly constructed.
        if <SID>ContainsOnlyWhitespace(l:line)
            let l:idx += 1
            continue
        endif

        let l:leading_char = strpart(l:line, 0, 1)

        if l:leading_char == "\t"
            let l:leading_tab_count += 1

        elseif l:leading_char == " "
            " only interested if we don't have a run of spaces followed by a
            " tab.
            if -1 == match(l:line, '^ \+\t')
                let l:leading_space_count += 1
                let l:num_spaces = strlen(matchstr(l:line, '^ \+'))
                let l:leading_space_dict[l:num_spaces] =
                    \ get(l:leading_space_dict, l:num_spaces, 0) + 1
            endif

        endif

        let l:idx += 1
    endwhile

    " TODO convert the following three 'sections' into actual functions

    " expandtab setting section
    if l:leading_tab_count > l:leading_space_count
        let l:verbose_msg = "Using tabs to indent."
        setlocal noexpandtab
    elseif l:leading_space_count > l:leading_tab_count
        let l:verbose_msg = "Using spaces to indent."
        setlocal expandtab
    else
        let l:verbose_msg = "Cannot determine whether indentation uses spaces or tabs; leaving the setting at the default."
        " since the program does not change the local value of expandtab (&l:expandtab),
        " it will automatically mirror the global value (&g:expandtab)
    endif

    " indent width setting section
    " if there's very little space indented lines, they tend to be misleading
    if l:leading_space_count > 0 && (100.0 * l:leading_space_count / (l:leading_space_count + l:leading_tab_count) >= 10.0)
        " I think absolutely no one uses 1 space indents
        call filter(l:leading_space_dict, 'v:key > 1')
        " Filter out those tab stops which occurred in < 10% of the lines
        call filter(l:leading_space_dict, '100.0 * v:val / l:leading_space_count >= 10.0')

        if len(l:leading_space_dict) > 0
            let l:remaining_indent_widths = keys(l:leading_space_dict)
            let l:leading_spaces_gcd = <SID>GCDOfMany(l:remaining_indent_widths)
            let l:indent_width = l:leading_spaces_gcd

            if l:leading_spaces_gcd != 0
                call <SID>SetLocalIndentWidth(l:indent_width)
            endif

            call <SID>RestrictIndentWidthWithinOptionRange(l:indent_width)
        else
            call <SID>SetDefaultLocalIndentWidth()
        endif
    else
        call <SID>SetDefaultLocalIndentWidth()
    endif

    " verbose message outputting section
    if &verbose >= g:detectindent_verbosity
        echom l:verbose_msg
            \ ."  leading_tab_count:" l:leading_tab_count
            \ .", leading_space_count:" l:leading_space_count
            \ .", leading_spaces_gcd:" l:leading_spaces_gcd
            \ .", leading_space_dict:" string(l:leading_space_dict)

        let changed_msg = []
        for [setting, oldval] in items(b:detectindent_original_buffer_settings)
            exec 'let newval = &'.setting
            if oldval != newval
                let changed_msg += [ setting." changed from ".oldval." to ".newval ]
            end
        endfor
        if len(changed_msg)
            echom "Changes from the buffer’s initial settings:" join(changed_msg, ", ")
        endif
    endif
endfun

command! -bar -nargs=0 DetectIndent call <SID>DetectIndent()

" TODO document the below option `g:detectindent_autodetect`
" first read its justification in commit eae149bb and confirm that it really is necessary;
"  if it is unnecessary, delete it
if get(g:, "detectindent_autodetect")
    augroup DetectIndent
        autocmd!
        autocmd BufReadPost * call <SID>DetectIndent()
    augroup END
endif
