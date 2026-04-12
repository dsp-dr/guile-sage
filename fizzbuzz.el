(defun fizzbuzz (n)
  (loop for i from 1 to n
        do (cond ((and (= (mod i 3) 0) (= (mod i 5) 0)) (princ "FizzBuzz\n"))
                 ((= (mod i 3) 0) (princ "Fizz\n"))
                 ((= (mod i 5) 0) (princ "Buzz\n"))
                 (t (princ (format "%d\n" i))))))
