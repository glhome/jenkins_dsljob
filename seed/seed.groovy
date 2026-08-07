def scripts = [
    'folders/**/*.groovy',
    'views/**/*.groovy',
    'jobs/**/*.groovy'
]

scripts.each {
    evaluate(new File("${WORKSPACE}/${it}"))
}