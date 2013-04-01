
cdef class GlobalRef:
    cdef jobject obj
    cdef JNIEnv *env

    def __cinit__(self):
        self.obj = NULL
        self.env = NULL

    def __dealloc__(self):
        if self.obj != NULL:
            self.env[0].DeleteGlobalRef(self.env, self.obj)
        self.obj = NULL
        self.env = NULL

    cdef void create(self, JNIEnv *env, jobject obj):
        self.env = env
        self.obj = env[0].NewGlobalRef(env, obj)


cdef GlobalRef create_global_ref(JNIEnv *env, jobject obj):
    cdef GlobalRef ret = GlobalRef()
    ret.create(env, obj)
    return ret
